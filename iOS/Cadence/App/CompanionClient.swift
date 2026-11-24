import CadenceCore
import CoreBluetooth
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
    /// Which of the Mac's keys that is (`CompanionKeys`); nil = the key older Macs shared with every phone.
    var keyID: String? = nil
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
        /// Local Network access is off for Cadence (Settings → Apps → Cadence), so Macs can't be found.
        case noLocalNetwork
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
    /// What's gone over the link with each Mac since the app opened (Settings → Mac → Advanced).
    let traffic = LinkTrafficStore()

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
    /// Bluetooth LE, shared by every Mac's link: the last resort when the network can't reach a Mac.
    @ObservationIgnored let bluetooth = BluetoothScanner()
    /// Whether the phone has Wi-Fi or a wired network, for the links' Bluetooth fallback.
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// The user's "Use Bluetooth when Wi-Fi can't connect" setting.
    var bluetoothEnabled = true {
        didSet { if bluetoothEnabled != oldValue { refreshBluetooth() } }
    }
    /// Whether Bluetooth can be used now, for the settings: nil = fine (or not asked yet).
    private(set) var bluetoothProblem: String?
    @ObservationIgnored private var helloResend: Timer?
    @ObservationIgnored private var running = false

    /// What this phone is called on the Macs. Blank = what iOS reports, which since iOS 16 is just
    /// "iPhone" (the Mac then shows the model, e.g. "iPhone 15 Pro") unless the app has Apple's
    /// user-assigned device name entitlement (Config/Cadence-DeviceName.entitlements).
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
        bluetooth.onStateChanged = { [weak self] in self?.refreshBluetooth() }
        refreshBluetooth()
    }

    /// Re-checks the setting and the permission for every link. Once iOS has granted access the
    /// scanner is created straight away; before that, only pairing creates it (and so asks).
    private func refreshBluetooth() {
        let authorization = BluetoothScanner.authorization
        if bluetoothEnabled, authorization == .allowedAlways { bluetooth.activate() }
        let allowed = bluetoothEnabled && authorization == .allowedAlways
        bluetoothProblem = if !bluetoothEnabled || authorization == .notDetermined {
            nil
        } else if authorization != .allowedAlways {
            "Cadence isn't allowed to use Bluetooth: turn it on in Settings → Apps → Cadence."
        } else if bluetooth.isActivated, !bluetooth.isUsable {
            "Bluetooth is off on this iPhone."
        } else {
            nil
        }
        for link in links {
            link.bluetoothAllowed = allowed
            link.bluetoothStateChanged()
        }
    }

    private func makeLink(_ mac: PairedMac) -> MacLink {
        let link = MacLink(mac: mac)
        link.scanner = bluetooth
        link.bluetoothAllowed = bluetoothEnabled && BluetoothScanner.authorization == .allowedAlways
        link.traffic = traffic
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
        let mac = PairedMac(id: invite.macID, name: invite.macName, nickname: existing?.mac.nickname, addresses: book,
                            keyID: invite.keyID)
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
        // The end of pairing is when iOS asks about Bluetooth, not at launch.
        if bluetoothEnabled {
            bluetooth.activate()
            refreshBluetooth()
        }
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
        traffic.reset(macID)
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
                for link in self.connected { link.sendHello() }
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
        startPathMonitor()
        // Macs paired before Bluetooth came along never saw the end-of-pairing prompt: ask once now.
        if bluetoothEnabled, !links.isEmpty, BluetoothScanner.authorization == .notDetermined {
            bluetooth.activate()
            refreshBluetooth()
        }
    }

    /// Wi-Fi or wired comes and goes: without either, Bonjour can't work and the links may go to
    /// Bluetooth sooner.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let local = path.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    for link in self.links { link.pathChanged(hasLocalNetwork: local) }
                }
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// Say goodbye and drop every link. Called when the app leaves the foreground.
    func stop() {
        running = false
        for link in links { link.stop() }
        pathMonitor?.cancel()
        pathMonitor = nil
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
    /// The network side's own state (Bonjour and direct dials).
    private var networkStatus: Status = .off { didSet { connectionChanged() } }
    /// A Bluetooth channel has been welcomed by the Mac (the last resort, `TransportPlanner`).
    private var bluetoothConnected = false { didSet { connectionChanged() } }
    /// Connected if either transport is; otherwise what the network side is doing.
    var status: Status { bluetoothConnected && networkStatus != .connected ? .connected : networkStatus }
    var isConnected: Bool { status == .connected }
    /// How the link is connected right now: the network wins when both are up.
    var transport: CompanionTransportKind? {
        networkStatus == .connected ? .network : bluetoothConnected ? .bluetooth : nil
    }
    @ObservationIgnored private var reportedConnected = false

    private func connectionChanged() {
        guard isConnected != reportedConnected else { return }
        reportedConnected = isConnected
        if !isConnected { features = [] }
        onConnectionChanged?(isConnected)
    }

    /// What this Mac said it understands beyond protocol 1 (`CompanionFeature`), while connected.
    private(set) var features: Set<String> = []
    func supports(_ feature: CompanionFeature) -> Bool { features.contains(feature.rawValue) }

    /// True once we've kept failing to reach the Mac for a while: the UI suggests scanning the
    /// pairing code again (the Mac may have moved networks, or Bonjour is blocked and its address changed).
    private(set) var needsRescan = false

    var displaying = false {
        didSet { if displaying != oldValue { activeChannel?.send(.displayState(displaying: displaying)) } }
    }

    @ObservationIgnored var hello: (() -> CompanionHello)?
    @ObservationIgnored var onMessage: ((CompanionMessage) -> Void)?
    @ObservationIgnored var onSaved: (() -> Void)?
    @ObservationIgnored var onConnectionChanged: ((Bool) -> Void)?
    /// Where this link's analytics go (`CompanionClient.traffic`).
    @ObservationIgnored weak var traffic: LinkTrafficStore?

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

    /// When to fall back to Bluetooth, and when to drop it for the network.
    @ObservationIgnored private var planner = TransportPlanner(bluetoothAllowed: false)
    /// Shared by every Mac's link (`CompanionClient`).
    @ObservationIgnored weak var scanner: BluetoothScanner?
    @ObservationIgnored private var bluetoothChannel: CompanionChannel?
    /// For the planner's grace periods, and the pause after a Bluetooth channel drops.
    @ObservationIgnored private var plannerTimer: Timer?
    @ObservationIgnored private var bluetoothRetryAt: Date?
    private static let bluetoothRetryAfter: TimeInterval = 5

    /// The user's setting and the Bluetooth permission, from `CompanionClient`.
    var bluetoothAllowed: Bool {
        get { planner.bluetoothAllowed }
        set {
            guard newValue != planner.bluetoothAllowed else { return }
            planner.bluetoothAllowed = newValue
            updateBluetooth()
        }
    }

    /// The channel messages go over: the network once it's welcomed, else Bluetooth if that is,
    /// else the network attempt in progress.
    private var activeChannel: CompanionChannel? {
        if networkStatus == .connected { return channel }
        if bluetoothConnected { return bluetoothChannel }
        return channel
    }

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
        guard let key else { networkStatus = .unpaired; return }
        running = true
        // A fresh start gives the network a fresh round before Bluetooth (retries call start() too).
        if !planner.running {
            planner.start()
            bluetoothRetryAt = nil
            updateBluetooth()
        }
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: CompanionService.type, domain: nil),
                                using: CompanionNetwork.parameters(key: key, keyID: mac.keyID))
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.found(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .failed(let error) = state { self.networkStatus = .failed(error.localizedDescription); self.restartBrowser() }
                // Access turned on (or the first-run prompt answered): back to looking.
                if case .ready = state {
                    if self.networkStatus == .noLocalNetwork { self.networkStatus = .searching }
                    self.planner.localNetworkAccess(denied: false, now: Date())
                    self.updateBluetooth()
                }
                if case .waiting(let error) = state {
                    let denied = Self.isLocalNetworkDenied(error)
                    if self.channel == nil {
                        self.networkStatus = denied ? .noLocalNetwork : .failed(error.localizedDescription)
                    }
                    if denied {
                        self.planner.localNetworkAccess(denied: true, now: Date())
                        self.updateBluetooth()
                    }
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        if channel == nil { networkStatus = .searching }
        scheduleDirect()
        armStuckTimer()
    }

    /// Bonjour browsing reports a denied Local Network permission as DNS-SD's PolicyDenied.
    private static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 } // kDNSServiceErr_PolicyDenied
        return false
    }

    private func armStuckTimer() {
        guard stuck == nil, status != .connected else { return }
        // Give every saved address a go before suggesting a rescan.
        let wait = Self.stuckAfter + Self.dialTimeoutAfter * Double(mac.directAddresses.count)
        stuck = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stuck = nil
                guard self.running, self.networkStatus != .connected else { return }
                // A whole round of Bonjour and every saved address without the Mac: Bluetooth may go next.
                self.planner.networkRoundFailedToConnect()
                self.updateBluetooth()
                if self.status != .connected { self.needsRescan = true }
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
        if let bluetoothChannel {
            bluetoothChannel.send(.displayState(displaying: false))
            bluetoothChannel.send(.bye(reason: "background"))
            let id = macID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                bluetoothChannel.close()
                self?.scanner?.release(id)
            }
        }
        bluetoothChannel = nil
        bluetoothConnected = false
        planner.stop()
        plannerTimer?.invalidate()
        plannerTimer = nil
        scanner?.unwant(macID)
        browser?.cancel()
        browser = nil
        endpoint = nil
        networkStatus = key == nil ? .unpaired : .off
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
        if candidates.isEmpty, channel == nil { networkStatus = .searching }
    }

    /// Macs that turned out not to be ours this session.
    @ObservationIgnored private var rejected: Set<NWEndpoint> = []

    private func connect(_ endpoint: NWEndpoint, direct: (host: String, port: UInt16)? = nil) {
        guard let key, running else { return }
        networkStatus = .connecting
        let connection = NWConnection(to: endpoint, using: CompanionNetwork.parameters(key: key, keyID: mac.keyID))
        let channel = CompanionChannel(transport: NetworkTransport(connection: connection))
        self.channel = channel
        dialTimeout?.invalidate()
        dialling = direct
        if direct != nil {
            dialTimeout = Timer.scheduledTimer(withTimeInterval: Self.dialTimeoutAfter, repeats: false) { [weak self, weak channel] _ in
                MainActor.assumeIsolated {
                    guard let self, let channel, self.channel === channel, self.networkStatus != .connected else { return }
                    channel.close(URLError(.timedOut))
                }
            }
        }
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.sendHello(on: channel)
        }
        channel.onMessage = { [weak self] message in self?.handle(message, over: .network) }
        channel.onTraffic = { [weak self] message, direction, bytes in
            guard let self else { return }
            self.traffic?.record(kind: message.kind, direction, bytes: bytes, peer: self.macID)
        }
        channel.onClose = { [weak self, weak channel] error in
            guard let self, self.channel === channel else { return }
            self.channel = nil
            self.planner.disconnected(.network)
            self.dialTimeout?.invalidate()
            let wasDirect = self.dialling != nil
            self.dialling = nil
            // With several Macs paired, an unnamed Bonjour result that refuses our key is another Mac.
            if let error = error as? NWError, case .tls = error, direct == nil, self.networkStatus != .connected {
                self.rejected.insert(endpoint)
            }
            if self.running, wasDirect, self.endpoint == nil, self.moreAddressesThisRound {
                // Another network's address didn't answer: try the next one straight away.
                self.networkStatus = .connecting
                self.scheduleDirect(after: 0.2)
                return
            }
            self.failures += 1
            if self.running {
                self.networkStatus = error.map { .failed(Self.describe($0)) } ?? .searching
                self.scheduleRetry()
                // A link that was up gets a new round of the network before Bluetooth.
                self.armStuckTimer()
                self.updateBluetooth()
            } else {
                self.networkStatus = .off
            }
        }
        channel.start()
    }

    private func handle(_ message: CompanionMessage, over kind: CompanionTransportKind) {
        // While both are up (moving onto the network), the Bluetooth channel only finishes its
        // handshake: the network one carries everything.
        if kind == .bluetooth, networkStatus == .connected {
            guard case .welcome = message else { return }
        }
        switch message {
        case .welcome(let welcomeID, let macName):
            if kind == .bluetooth {
                guard welcomeID == mac.id else { bluetoothChannel?.close(); return }
                return bluetoothWelcomed(macName: macName)
            }
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
            networkStatus = .connected
            planner.connected(.network)
            updateBluetooth()
        case .features(let list):
            features = Set(list)
        case .rekey(let keyID, let key):
            // A key of this phone's own, in place of the one the Mac shared with every phone; used
            // from the next connection (this one carries on with the old one).
            guard key.count == PairingInvite.keyLength, !keyID.isEmpty else { return }
            CompanionIdentity.store(key: key, mac.keyAccount)
            update { $0.keyID = keyID }
        case .address(let hosts, let port):
            // Where the Mac is on the network we're connected over: keep it alongside the others,
            // and count it as working now.
            update { mac in
                var book = mac.book()
                // Over Bluetooth the phone isn't on that network: keep the address for later, untried.
                book.learn(hosts: hosts, port: port, now: Date(), worked: kind == .network)
                mac.addresses = book
            }
        case .bye(let reason):
            if kind == .bluetooth { bluetoothChannel?.close(); break }
            channel?.close()
            if reason != "stopped" { networkStatus = .failed(reason) }
        default:
            break
        }
        onMessage?(message)
    }

    func send(_ message: CompanionMessage) { activeChannel?.send(message) }

    /// Says hello again (the phone was renamed).
    func sendHello() {
        for channel in [channel, bluetoothChannel].compactMap({ $0 }) { sendHello(on: channel) }
    }

    // MARK: Bluetooth (last resort)

    /// The phone's network path changed: Wi-Fi or wired (so Bonjour can work), or neither.
    func pathChanged(hasLocalNetwork: Bool) {
        planner.pathChanged(hasLocalNetwork: hasLocalNetwork, now: Date())
        updateBluetooth()
    }

    /// Bluetooth became usable or not (switched on/off, permission answered): look again.
    func bluetoothStateChanged() { updateBluetooth() }

    /// Follows the planner: asks the scanner for a channel when Bluetooth is the way to go, and
    /// drops a Bluetooth channel once the network is up (or Bluetooth isn't allowed any more).
    private func updateBluetooth() {
        plannerTimer?.invalidate()
        plannerTimer = nil
        if let old = bluetoothChannel, planner.shouldDropBluetooth || !planner.bluetoothAllowed {
            bluetoothChannel = nil
            bluetoothConnected = false
            planner.disconnected(.bluetooth)
            old.send(.bye(reason: planner.bluetoothAllowed ? "upgraded" : "bluetooth off"))
            let id = macID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                old.close()
                self?.scanner?.release(id)
            }
        }
        let now = Date()
        var wait = planner.nextDeadline(after: now)
        if planner.wantsBluetooth(now: now), bluetoothChannel == nil, let scanner, scanner.isUsable {
            if let retry = bluetoothRetryAt, retry > now {
                scanner.unwant(macID)
                wait = min(wait ?? retry, retry)
            } else {
                scanner.want(macID) { [weak self] channel in self?.bluetoothOpened(channel) }
            }
        } else {
            scanner?.unwant(macID)
        }
        if let wait {
            plannerTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, wait.timeIntervalSince(now)), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBluetooth() }
            }
        }
    }

    /// The scanner opened an L2CAP channel to this Mac: run the link over it.
    private func bluetoothOpened(_ l2cap: CBL2CAPChannel) {
        guard running, bluetoothChannel == nil, let key else { scanner?.release(macID); return }
        let transport = BluetoothTransport(channel: l2cap, role: .phone(key: key, identity: CompanionKeys.identity(for: mac.keyID)))
        let channel = CompanionChannel(transport: transport)
        bluetoothChannel = channel
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.sendHello(on: channel)
        }
        channel.onMessage = { [weak self] message in self?.handle(message, over: .bluetooth) }
        channel.onTraffic = { [weak self] message, direction, bytes in
            guard let self else { return }
            self.traffic?.record(kind: message.kind, direction, bytes: bytes, peer: self.macID, over: .bluetooth)
        }
        channel.onClose = { [weak self, weak channel] _ in
            guard let self, self.bluetoothChannel === channel else { return }
            self.bluetoothChannel = nil
            self.bluetoothConnected = false
            self.planner.disconnected(.bluetooth)
            self.scanner?.release(self.macID)
            // Out of range, or the Mac went away: pause before looking again.
            self.bluetoothRetryAt = Date().addingTimeInterval(Self.bluetoothRetryAfter)
            self.updateBluetooth()
        }
        channel.start()
    }

    /// The Mac welcomed us over Bluetooth.
    private func bluetoothWelcomed(macName: String) {
        needsRescan = false
        bluetoothRetryAt = nil
        update { $0.name = macName }
        bluetoothConnected = true
        planner.connected(.bluetooth)
        // The network may have come up while this was connecting: then this goes straight away.
        updateBluetooth()
    }

    /// Hello, with which of the Mac's keys this is and proof that this TLS session was made with it.
    private func sendHello(on channel: CompanionChannel) {
        guard var hello = hello?(), let key, let binding = channel.sessionBinding() else { return }
        hello.keyID = mac.keyID
        hello.proof = CompanionKeys.proof(key: key, binding: binding)
        channel.send(.hello(hello))
    }

    private static func describe(_ error: Error) -> String {
        if let nw = error as? NWError, case .tls = nw {
            return "The Mac didn't accept this phone's key. Pair again from the Mac's Settings → iPhone."
        }
        return error.localizedDescription
    }
}
