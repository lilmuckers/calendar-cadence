import CadenceCore
import Foundation
import Network
import Observation
import UIKit

/// A Mac this phone paired with.
struct PairedMac: Codable, Equatable, Identifiable {
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

    /// Where this Mac's link key lives in the Keychain (each Mac has its own).
    var keyAccount: String { CompanionClient.keyAccount(for: id) }
}

/// The phone's links to every Mac it paired with, highest priority first. Each Mac has its own
/// key, addresses and connection (`MacLink`); this keeps the list, its order and the bits that are
/// the same for all of them (this phone's name, whether it's displaying).
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

    private static let macsKey = "Cadence.companion.macs"
    /// Before several Macs: the one paired Mac, and its key under `legacyKeyAccount`.
    private static let legacyMacKey = "Cadence.companion.mac"
    private static let legacyKeyAccount = "companion.linkKey"
    private static let deviceNameKey = "Cadence.companion.deviceName"

    nonisolated static func keyAccount(for macID: String) -> String { "companion.linkKey.\(macID)" }

    /// Every paired Mac's link, in the user's priority order.
    private(set) var links: [MacLink] = []

    /// Paired Macs, highest priority first.
    var macs: [PairedMac] { links.map(\.mac) }
    /// Connected links, highest priority first.
    var connected: [MacLink] { links.filter(\.isConnected) }
    var isConnected: Bool { links.contains(where: \.isConnected) }

    /// The Mac to name when one name will do: the highest-priority connected one, else the first.
    var mac: PairedMac? { (connected.first ?? links.first)?.mac }

    /// One status for the whole list: connected if any Mac is, otherwise the first Mac's.
    var status: Status {
        if links.isEmpty { return .unpaired }
        if isConnected { return .connected }
        if let busy = links.first(where: { $0.status == .connecting }) { return busy.status }
        return links[0].status
    }

    /// Nothing connected and some Mac has been unreachable for a while: suggest scanning again.
    var needsRescan: Bool { !isConnected && links.contains(where: \.needsRescan) }

    func link(_ macID: String) -> MacLink? { links.first { $0.mac.id == macID } }

    /// Sent to every Mac whenever it changes. A Mac only goes quiet while this is true.
    var displaying = false {
        didSet { if displaying != oldValue { for link in links { link.displaying = displaying } } }
    }

    /// A message from the Mac with this id.
    @ObservationIgnored var onMessage: ((String, CompanionMessage) -> Void)?
    /// A Mac's live link dropped (it takes back anything waiting on the phone).
    @ObservationIgnored var onDisconnected: ((String) -> Void)?
    /// A Mac connected or dropped, or the list or its order changed.
    @ObservationIgnored var onLinksChanged: (() -> Void)?

    @ObservationIgnored private let deviceID = CompanionIdentity.deviceID("Cadence.companion.deviceID")
    @ObservationIgnored private var helloResend: Timer?
    @ObservationIgnored private var running = false

    /// What this phone is called on the Macs. Blank = what iOS reports, which since iOS 16 is just
    /// "iPhone" (the Mac then shows the model, e.g. "iPhone 16 Pro").
    private(set) var deviceName: String = UserDefaults.standard.string(forKey: CompanionClient.deviceNameKey) ?? ""

    /// The name the Mac shows when the user hasn't set one.
    var defaultDeviceName: String {
        CompanionDeviceName.label(name: UIDevice.current.name, model: Self.modelIdentifier)
    }

    init() {
        var macs = UserDefaults.standard.data(forKey: Self.macsKey).flatMap { try? JSONDecoder().decode([PairedMac].self, from: $0) }
        if macs == nil, let old = UserDefaults.standard.data(forKey: Self.legacyMacKey).flatMap({ try? JSONDecoder().decode(PairedMac.self, from: $0) }) {
            // One paired Mac from before: it becomes the first in the list, and its key moves to its own slot.
            if let key = CompanionIdentity.storedKey(Self.legacyKeyAccount) {
                CompanionIdentity.store(key: key, old.keyAccount)
                CompanionIdentity.store(key: nil, Self.legacyKeyAccount)
            }
            macs = [old]
            UserDefaults.standard.removeObject(forKey: Self.legacyMacKey)
        }
        links = (macs ?? []).map { mac in
            // Move older saves (one address set) into the address book, and drop sets gone stale.
            var mac = mac
            var book = mac.book()
            book.prune(now: Date())
            mac.addresses = book
            mac.hosts = nil
            mac.port = nil
            return makeLink(mac)
        }
        save()
    }

    private func makeLink(_ mac: PairedMac) -> MacLink {
        let link = MacLink(mac: mac)
        link.hello = { [weak self] in self?.hello ?? CompanionHello(deviceID: "", deviceName: "", displaying: false) }
        link.displaying = displaying
        let id = mac.id
        link.onMessage = { [weak self] message in self?.onMessage?(id, message) }
        link.onSaved = { [weak self] in self?.save() }
        link.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            if !connected { self.onDisconnected?(id) }
            self.onLinksChanged?()
        }
        return link
    }

    // MARK: Pairing

    /// Adds a Mac (to the end of the list), or refreshes one already paired: a code scanned on a
    /// second network adds that network's addresses rather than replacing, and the name the user
    /// gave it stays.
    func pair(_ invite: PairingInvite) {
        let existing = link(invite.macID)
        existing?.stop()
        var book = existing?.mac.book() ?? CompanionAddressBook()
        book.learn(hosts: invite.hosts, port: invite.port, now: Date(), worked: false)
        let mac = PairedMac(id: invite.macID, name: invite.macName, nickname: existing?.mac.nickname, addresses: book)
        CompanionIdentity.store(key: invite.key, mac.keyAccount)
        if let existing {
            existing.replace(mac)
        } else {
            links.append(makeLink(mac))
        }
        save()
        onLinksChanged?()
        // Pairing happens in the app, so it's in the foreground: connect now.
        running = true
        link(invite.macID)?.start()
    }

    /// Give a paired Mac a name of the user's own; blank goes back to the Mac's computer name.
    func rename(_ macID: String, _ nickname: String) {
        guard let link = link(macID) else { return }
        var updated = link.mac
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.nickname = trimmed.isEmpty || trimmed == updated.name ? nil : trimmed
        guard updated != link.mac else { return }
        link.replace(updated)
        save()
    }

    /// Reorder (Settings' list): the first Mac opens meetings that several Macs have.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        links.move(fromOffsets: source, toOffset: destination)
        save()
        onLinksChanged?()
    }

    func unpair(_ macID: String) {
        guard let link = link(macID) else { return }
        link.send(.bye(reason: "unpaired"))
        link.stop()
        CompanionIdentity.store(key: nil, link.mac.keyAccount)
        links.removeAll { $0.mac.id == macID }
        save()
        onLinksChanged?()
    }

    /// Name this phone for the Macs; blank goes back to what iOS reports. Connected Macs hear it shortly.
    func renameDevice(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != deviceName else { return }
        deviceName = trimmed
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: Self.deviceNameKey) }
        else { UserDefaults.standard.set(trimmed, forKey: Self.deviceNameKey) }
        // Typing sends a change per keystroke; tell the Macs once it settles.
        helloResend?.invalidate()
        helloResend = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for link in self.connected { link.send(.hello(self.hello)) }
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

    private func save() {
        if let data = try? JSONEncoder().encode(macs) { UserDefaults.standard.set(data, forKey: Self.macsKey) }
    }

    // MARK: Lifecycle

    /// Browse and connect to every paired Mac. Called when the app comes to the foreground.
    func start() {
        running = true
        for link in links { link.start() }
    }

    /// Say goodbye and drop every link. Called when the app leaves the foreground.
    func stop() {
        running = false
        for link in links { link.stop() }
    }

    func send(_ message: CompanionMessage, to macID: String) { link(macID)?.send(message) }

    /// Sends to every connected Mac.
    func broadcast(_ message: CompanionMessage) {
        for link in connected { link.send(message) }
    }
}

/// The phone end of one Mac's link: browses Bonjour for that Mac (matched by the id in the TXT
/// record), connects with its link key, says hello, and keeps it told whether the phone's displaying.
@MainActor
@Observable
final class MacLink: Identifiable {
    typealias Status = CompanionClient.Status

    nonisolated var id: String { macID }
    private nonisolated let macID: String

    private(set) var mac: PairedMac
    private(set) var status: Status = .off {
        didSet {
            guard (oldValue == .connected) != (status == .connected) else { return }
            if status != .connected { features = [] }
            onConnectionChanged?(status == .connected)
        }
    }
    var isConnected: Bool { status == .connected }

    /// What this Mac said it understands beyond protocol 1 (`CompanionFeature`), while connected.
    private(set) var features: Set<String> = []
    func supports(_ feature: CompanionFeature) -> Bool { features.contains(feature.rawValue) }

    /// True once we've kept failing to reach the Mac for a while: the UI suggests scanning the
    /// pairing code again (the Mac may have moved networks, or Bonjour is blocked and its address changed).
    private(set) var needsRescan = false

    var displaying = false {
        didSet { if displaying != oldValue { channel?.send(.displayState(displaying: displaying)) } }
    }

    @ObservationIgnored var hello: (() -> CompanionHello)?
    @ObservationIgnored var onMessage: ((CompanionMessage) -> Void)?
    @ObservationIgnored var onSaved: (() -> Void)?
    @ObservationIgnored var onConnectionChanged: ((Bool) -> Void)?

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
    @ObservationIgnored private var running = false
    @ObservationIgnored private var failures = 0

    init(mac: PairedMac) {
        self.mac = mac
        self.macID = mac.id
    }

    private var key: Data? { CompanionIdentity.storedKey(mac.keyAccount) }

    /// A fresh pairing code (or a rename): new details, and another go at every address.
    func replace(_ updated: PairedMac) {
        mac = updated
        directIndex = 0
        failures = 0
        needsRescan = false
    }

    private func update(_ body: (inout PairedMac) -> Void) {
        var updated = mac
        body(&updated)
        guard updated != mac else { return }
        mac = updated
        onSaved?()
    }

    // MARK: Lifecycle

    func start() {
        guard let key else { status = .unpaired; return }
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
        let wait = Self.stuckAfter + Self.dialTimeoutAfter * Double(mac.directAddresses.count)
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
                guard let self, self.running, self.channel == nil, self.endpoint == nil else { return }
                let addresses = self.mac.directAddresses
                guard !addresses.isEmpty else { return }
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
        let count = mac.directAddresses.count
        return count > 1 && directIndex % count != 0
    }

    /// Say goodbye and drop the link, so the Mac stops being quiet straight away rather than after a timeout.
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
        status = key == nil ? .unpaired : .off
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
        let ours = results.first { result in
            if case .bonjour(let txt) = result.metadata { return txt[CompanionService.macIDKey] == mac.id }
            return false
        }
        // Without our TXT match, skip Macs that announce someone else's id (another paired Mac's
        // link handles those) and Macs already found not to be ours.
        let unnamed = results.filter { result in
            if case .bonjour(let txt) = result.metadata, let id = txt[CompanionService.macIDKey] { return id == mac.id }
            return true
        }
        let candidates = ours.map { [$0.endpoint] } ?? unnamed.map(\.endpoint).filter { !rejected.contains($0) }
        endpoint = candidates.first
        if let endpoint, channel == nil { connect(endpoint) }
        if candidates.isEmpty, channel == nil { status = .searching }
    }

    /// Macs that turned out not to be ours this session.
    @ObservationIgnored private var rejected: Set<NWEndpoint> = []

    private func connect(_ endpoint: NWEndpoint, direct: (host: String, port: UInt16)? = nil) {
        guard let key, running else { return }
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
            guard let self, let channel, let hello = self.hello?() else { return }
            channel.send(.hello(hello))
        }
        channel.onMessage = { [weak self] message in self?.handle(message) }
        channel.onClose = { [weak self, weak channel] error in
            guard let self, self.channel === channel else { return }
            self.channel = nil
            self.dialTimeout?.invalidate()
            let wasDirect = self.dialling != nil
            self.dialling = nil
            // With several Macs paired, an unnamed Bonjour result that refuses our key is another Mac.
            if let error = error as? NWError, case .tls = error, direct == nil, self.status != .connected {
                self.rejected.insert(endpoint)
            }
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
            } else {
                self.status = .off
            }
        }
        channel.start()
    }

    private func handle(_ message: CompanionMessage) {
        switch message {
        case .welcome(let welcomeID, let macName):
            guard welcomeID == mac.id else {
                if let endpoint { rejected.insert(endpoint) }
                channel?.close()
                return
            }
            failures = 0
            needsRescan = false
            dialTimeout?.invalidate()
            stuck?.invalidate()
            stuck = nil
            let dialled = dialling
            update { mac in
                if let dialled {
                    var book = mac.book()
                    book.markWorked(host: dialled.host, port: dialled.port, now: Date())
                    mac.addresses = book
                }
                mac.name = macName
            }
            // Next time, start from the address that worked.
            if dialled != nil { directIndex = 0 }
            status = .connected
        case .features(let list):
            features = Set(list)
        case .address(let hosts, let port):
            // Where the Mac is on the network we're connected over: keep it alongside the others,
            // and count it as working now.
            update { mac in
                var book = mac.book()
                book.learn(hosts: hosts, port: port, now: Date(), worked: true)
                mac.addresses = book
            }
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
