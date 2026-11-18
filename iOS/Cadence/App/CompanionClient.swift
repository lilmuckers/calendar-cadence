import CadenceCore
import Foundation
import Network
import Observation
import UIKit

/// The Mac this phone paired with.
struct PairedMac: Codable, Equatable {
    var id: String
    var name: String
    /// LAN addresses and port from the pairing code, dialled when Bonjour finds nothing.
    var hosts: [String]? = nil
    var port: UInt16? = nil

    var directEndpoints: [NWEndpoint] {
        guard let port, let p = NWEndpoint.Port(rawValue: port) else { return [] }
        return (hosts ?? []).map { .hostPort(host: NWEndpoint.Host($0), port: p) }
    }
}

/// The phone end of the Mac link: browses Bonjour for *its* Mac (matched by the id in the TXT record),
/// connects with the paired link key, says hello, and keeps the Mac told whether it's displaying.
@MainActor
@Observable
final class CompanionClient {
    enum Status: Equatable {
        case unpaired
        case off
        case searching
        case connecting
        case connected
        case failed(String)
    }

    private static let macKey = "Cadence.companion.mac"

    private(set) var status: Status = .unpaired {
        didSet { if oldValue == .connected, status != .connected { onDisconnected?() } }
    }
    /// Called when a live link drops (the Mac takes back anything waiting on the phone).
    @ObservationIgnored var onDisconnected: (() -> Void)?
    private(set) var mac: PairedMac? =
        UserDefaults.standard.data(forKey: CompanionClient.macKey).flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }

    var isConnected: Bool { status == .connected }

    /// True once we've kept failing to reach the Mac for a while: the UI suggests scanning the
    /// pairing code again (the Mac may have moved networks, or Bonjour is blocked and its address changed).
    private(set) var needsRescan = false

    /// Sent to the Mac whenever it changes. The Mac only goes quiet while this is true.
    var displaying = false {
        didSet { if displaying != oldValue { channel?.send(.displayState(displaying: displaying)) } }
    }

    @ObservationIgnored var onMessage: ((CompanionMessage) -> Void)?
    @ObservationIgnored private let deviceID = CompanionIdentity.deviceID("Cadence.companion.deviceID")
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var channel: CompanionChannel?
    @ObservationIgnored private var endpoint: NWEndpoint?
    @ObservationIgnored private var retry: Timer?
    @ObservationIgnored private var direct: Timer?
    @ObservationIgnored private var directIndex = 0
    @ObservationIgnored private var stuck: Timer?
    private static let stuckAfter: TimeInterval = 20
    @ObservationIgnored private var running = false
    @ObservationIgnored private var failures = 0

    init() {
        status = mac == nil ? .unpaired : .off
    }

    // MARK: Pairing

    func pair(_ invite: PairingInvite) {
        stop()
        CompanionIdentity.store(key: invite.key)
        mac = PairedMac(id: invite.macID, name: invite.macName, hosts: invite.hosts, port: invite.port)
        if let data = try? JSONEncoder().encode(mac) { UserDefaults.standard.set(data, forKey: Self.macKey) }
        failures = 0
        needsRescan = false
        start()
    }

    func unpair() {
        channel?.send(.bye(reason: "unpaired"))
        stop()
        CompanionIdentity.store(key: nil)
        mac = nil
        UserDefaults.standard.removeObject(forKey: Self.macKey)
        needsRescan = false
        status = .unpaired
    }

    // MARK: Lifecycle

    /// Browse and connect. Called when the app comes to the foreground.
    func start() {
        guard mac != nil, let key = CompanionIdentity.storedKey() else { status = .unpaired; return }
        running = true
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: CompanionService.type, domain: nil),
                                using: CompanionNetwork.parameters(key: key))
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.found(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .failed(let error) = state { self.status = .failed(error.localizedDescription); self.restartBrowser() }
                if case .waiting(let error) = state, self.channel == nil { self.status = .failed(error.localizedDescription) }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        if channel == nil { status = .searching }
        scheduleDirect()
        armStuckTimer()
    }

    private func armStuckTimer() {
        guard stuck == nil, status != .connected else { return }
        stuck = Timer.scheduledTimer(withTimeInterval: Self.stuckAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stuck = nil
                if self.running, self.status != .connected { self.needsRescan = true }
            }
        }
    }

    /// If Bonjour hasn't turned up the Mac shortly, dial the address from the pairing code instead.
    /// Some networks and Mac security tools drop multicast DNS while plain TCP still gets through.
    private func scheduleDirect() {
        direct?.invalidate()
        direct = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, self.channel == nil, self.endpoint == nil,
                      let endpoints = self.mac?.directEndpoints, !endpoints.isEmpty else { return }
                let endpoint = endpoints[self.directIndex % endpoints.count]
                self.directIndex += 1
                self.connect(endpoint)
            }
        }
    }

    /// Say goodbye and drop the link. Called when the app leaves the foreground, so the Mac
    /// stops being quiet straight away rather than after a timeout.
    func stop() {
        running = false
        retry?.invalidate()
        direct?.invalidate()
        stuck?.invalidate()
        stuck = nil
        if let channel {
            channel.send(.displayState(displaying: false))
            channel.send(.bye(reason: "background"))
            // Give the frames a moment to leave before cancelling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { channel.close() }
        }
        channel = nil
        browser?.cancel()
        browser = nil
        endpoint = nil
        status = mac == nil ? .unpaired : .off
    }

    private func restartBrowser() {
        browser?.cancel()
        browser = nil
        scheduleRetry()
    }

    private func scheduleRetry() {
        retry?.invalidate()
        let delay = min(30, pow(2, Double(min(failures, 5))))
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.start()
                if let endpoint = self.endpoint, self.channel == nil { self.connect(endpoint) }
                // start() is a no-op while the browser runs, so re-arm the direct dial here too.
                if self.endpoint == nil { self.scheduleDirect() }
            }
        }
    }

    /// Every advertised Cadence Mac. TXT records don't always resolve (e.g. over loopback), so we
    /// don't rely on them: we try each Mac, and only ours accepts our key and answers with our Mac's id.
    private func found(_ results: Set<NWBrowser.Result>) {
        guard let mac else { return }
        let ours = results.first { result in
            if case .bonjour(let txt) = result.metadata { return txt[CompanionService.macIDKey] == mac.id }
            return false
        }
        let candidates = ours.map { [$0.endpoint] } ?? results.map(\.endpoint).filter { !rejected.contains($0) }
        endpoint = candidates.first
        if let endpoint, channel == nil { connect(endpoint) }
        if candidates.isEmpty, channel == nil { status = .searching }
    }

    /// Macs that turned out not to be ours this session.
    @ObservationIgnored private var rejected: Set<NWEndpoint> = []

    private func connect(_ endpoint: NWEndpoint) {
        guard let key = CompanionIdentity.storedKey(), running else { return }
        status = .connecting
        let channel = CompanionChannel(connection: NWConnection(to: endpoint, using: CompanionNetwork.parameters(key: key)))
        self.channel = channel
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            channel.send(.hello(CompanionHello(deviceID: self.deviceID, deviceName: UIDevice.current.name, displaying: self.displaying)))
        }
        channel.onMessage = { [weak self] message in self?.handle(message) }
        channel.onClose = { [weak self, weak channel] error in
            guard let self, self.channel === channel else { return }
            self.channel = nil
            self.failures += 1
            if self.running {
                self.status = error.map { .failed(Self.describe($0)) } ?? .searching
                self.scheduleRetry()
            }
        }
        channel.start()
    }

    private func handle(_ message: CompanionMessage) {
        switch message {
        case .welcome(let macID, let macName):
            guard macID == mac?.id else {
                if let endpoint { rejected.insert(endpoint) }
                channel?.close()
                return
            }
            failures = 0
            status = .connected
            needsRescan = false
            stuck?.invalidate()
            stuck = nil
            if mac?.name != macName, var updated = mac {
                updated.name = macName
                mac = updated
                if let data = try? JSONEncoder().encode(mac) { UserDefaults.standard.set(data, forKey: Self.macKey) }
            }
        case .address(let hosts, let port):
            guard var updated = mac, updated.hosts != hosts || updated.port != port else { break }
            updated.hosts = hosts
            updated.port = port
            mac = updated
            if let data = try? JSONEncoder().encode(mac) { UserDefaults.standard.set(data, forKey: Self.macKey) }
        case .bye(let reason):
            channel?.close()
            if reason != "stopped" { status = .failed(reason) }
        default:
            break
        }
        onMessage?(message)
    }

    func send(_ message: CompanionMessage) { channel?.send(message) }

    private static func describe(_ error: Error) -> String {
        if let nw = error as? NWError, case .tls = nw {
            return "The Mac didn't accept this phone's key. Pair again from the Mac's Settings → iPhone."
        }
        return error.localizedDescription
    }
}
