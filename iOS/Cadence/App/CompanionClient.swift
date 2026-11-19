import CadenceCore
import Foundation
import Network
import Observation
import UIKit

/// The Mac this phone paired with.
struct PairedMac: Codable, Equatable {
    var id: String
    /// The Mac's own computer name (often a serial number on managed laptops).
    var name: String
    /// What the user calls it on this phone ("Work laptop"). Nil = use `name`.
    var nickname: String? = nil
    /// LAN addresses and port from the pairing code, as saved before the address book. Only read to
    /// migrate older saves into `addresses`.
    var hosts: [String]? = nil
    var port: UInt16? = nil
    /// Every network's addresses the Mac has been seen at (pairing codes, and the Mac telling a
    /// connected phone), dialled in turn when Bonjour finds nothing.
    var addresses: CompanionAddressBook? = nil

    var displayName: String { nickname ?? name }

    /// The address book, seeded from the old single address set if this save predates it.
    func book(now: Date = Date()) -> CompanionAddressBook {
        if let addresses { return addresses }
        var book = CompanionAddressBook()
        book.learn(hosts: hosts ?? [], port: port, now: now, worked: false)
        return book
    }

    /// Addresses to dial directly, the most recently working network first.
    var directAddresses: [(host: String, port: UInt16)] { book().dialOrder }
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
    private static let deviceNameKey = "Cadence.companion.deviceName"

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
    /// A direct dial that hasn't been welcomed by then is given up, so the next address gets a go
    /// (an address from another network usually just hangs rather than failing).
    @ObservationIgnored private var dialTimeout: Timer?
    private static let dialTimeoutAfter: TimeInterval = 5
    /// The address being dialled directly, if this connection is a direct dial.
    @ObservationIgnored private var dialling: (host: String, port: UInt16)?
    @ObservationIgnored private var helloResend: Timer?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var failures = 0

    /// What this phone is called on the Mac. Blank = what iOS reports, which since iOS 16 is just
    /// "iPhone" (the Mac then shows the model, e.g. "iPhone 16 Pro").
    private(set) var deviceName: String = UserDefaults.standard.string(forKey: CompanionClient.deviceNameKey) ?? ""

    /// The name the Mac shows when the user hasn't set one.
    var defaultDeviceName: String {
        CompanionDeviceName.label(name: UIDevice.current.name, model: Self.modelIdentifier)
    }

    init() {
        status = mac == nil ? .unpaired : .off
        // Move older saves (one address set) into the address book, and drop sets gone stale.
        if var mac {
            var book = mac.book()
            book.prune(now: Date())
            if mac.addresses != book || mac.hosts != nil {
                mac.addresses = book
                mac.hosts = nil
                mac.port = nil
                self.mac = mac
                saveMac()
            }
        }
    }

    // MARK: Pairing

    func pair(_ invite: PairingInvite) {
        stop()
        CompanionIdentity.store(key: invite.key)
        // Re-pairing the same Mac keeps the name the user gave it, and the networks it was seen on:
        // a code scanned on a second network adds that network's addresses rather than replacing.
        let same = mac?.id == invite.macID
        var book = same ? mac?.book() ?? CompanionAddressBook() : CompanionAddressBook()
        book.learn(hosts: invite.hosts, port: invite.port, now: Date(), worked: false)
        mac = PairedMac(id: invite.macID, name: invite.macName, nickname: same ? mac?.nickname : nil, addresses: book)
        saveMac()
        directIndex = 0
        failures = 0
        needsRescan = false
        start()
    }

    /// Give the paired Mac a name of the user's own; blank goes back to the Mac's computer name.
    func rename(_ nickname: String) {
        guard var updated = mac else { return }
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.nickname = trimmed.isEmpty || trimmed == updated.name ? nil : trimmed
        guard updated != mac else { return }
        mac = updated
        saveMac()
    }

    /// Name this phone for the Mac; blank goes back to what iOS reports. A connected Mac hears it shortly.
    func renameDevice(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != deviceName else { return }
        deviceName = trimmed
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: Self.deviceNameKey) }
        else { UserDefaults.standard.set(trimmed, forKey: Self.deviceNameKey) }
        // Typing sends a change per keystroke; tell the Mac once it settles.
        helloResend?.invalidate()
        helloResend = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .connected else { return }
                self.channel?.send(.hello(self.hello))
            }
        }
    }

    private var hello: CompanionHello {
        CompanionHello(deviceID: deviceID, deviceName: deviceName.isEmpty ? UIDevice.current.name : deviceName,
                       deviceModel: Self.modelIdentifier, displaying: displaying)
    }

    /// "iPhone17,1" (the simulator reports the model it's simulating).
    static let modelIdentifier: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    private func saveMac() {
        if let data = try? JSONEncoder().encode(mac) { UserDefaults.standard.set(data, forKey: Self.macKey) }
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
        // Give every saved address a go before suggesting a rescan.
        let wait = Self.stuckAfter + Self.dialTimeoutAfter * Double(mac?.directAddresses.count ?? 0)
        stuck = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stuck = nil
                if self.running, self.status != .connected { self.needsRescan = true }
            }
        }
    }

    /// If Bonjour hasn't turned up the Mac shortly, dial the address from the pairing code instead.
    /// Some networks and Mac security tools drop multicast DNS while plain TCP still gets through.
    private func scheduleDirect(after delay: TimeInterval = 3) {
        direct?.invalidate()
        direct = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, self.channel == nil, self.endpoint == nil,
                      let addresses = self.mac?.directAddresses, !addresses.isEmpty else { return }
                let address = addresses[self.directIndex % addresses.count]
                self.directIndex += 1
                guard let port = NWEndpoint.Port(rawValue: address.port) else { return }
                self.connect(.hostPort(host: NWEndpoint.Host(address.host), port: port), direct: address)
            }
        }
    }

    /// Whether a failed direct dial should move straight on to the next address rather than backing
    /// off: true until every address has had a go this round.
    private var moreAddressesThisRound: Bool {
        let count = mac?.directAddresses.count ?? 0
        return count > 1 && directIndex % count != 0
    }

    /// Say goodbye and drop the link. Called when the app leaves the foreground, so the Mac
    /// stops being quiet straight away rather than after a timeout.
    func stop() {
        running = false
        retry?.invalidate()
        direct?.invalidate()
        dialTimeout?.invalidate()
        dialling = nil
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

    private func connect(_ endpoint: NWEndpoint, direct: (host: String, port: UInt16)? = nil) {
        guard let key = CompanionIdentity.storedKey(), running else { return }
        status = .connecting
        let channel = CompanionChannel(connection: NWConnection(to: endpoint, using: CompanionNetwork.parameters(key: key)))
        self.channel = channel
        dialTimeout?.invalidate()
        dialling = direct
        if direct != nil {
            dialTimeout = Timer.scheduledTimer(withTimeInterval: Self.dialTimeoutAfter, repeats: false) { [weak self, weak channel] _ in
                MainActor.assumeIsolated {
                    guard let self, let channel, self.channel === channel, self.status != .connected else { return }
                    channel.close(URLError(.timedOut))
                }
            }
        }
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            channel.send(.hello(self.hello))
        }
        channel.onMessage = { [weak self] message in self?.handle(message) }
        channel.onClose = { [weak self, weak channel] error in
            guard let self, self.channel === channel else { return }
            self.channel = nil
            self.dialTimeout?.invalidate()
            let wasDirect = self.dialling != nil
            self.dialling = nil
            if self.running, wasDirect, self.endpoint == nil, self.moreAddressesThisRound {
                // Another network's address didn't answer: try the next one straight away.
                self.status = .connecting
                self.scheduleDirect(after: 0.2)
                return
            }
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
            dialTimeout?.invalidate()
            if let dialled = dialling, var updated = mac {
                var book = updated.book()
                book.markWorked(host: dialled.host, port: dialled.port, now: Date())
                updated.addresses = book
                mac = updated
                saveMac()
                // Next time, start from the address that worked.
                directIndex = 0
            }
            stuck?.invalidate()
            stuck = nil
            if mac?.name != macName, var updated = mac {
                updated.name = macName
                mac = updated
                saveMac()
            }
        case .address(let hosts, let port):
            // Where the Mac is on the network we're connected over: keep it alongside the others,
            // and count it as working now.
            guard var updated = mac else { break }
            var book = updated.book()
            book.learn(hosts: hosts, port: port, now: Date(), worked: true)
            guard book != updated.addresses else { break }
            updated.addresses = book
            mac = updated
            saveMac()
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
