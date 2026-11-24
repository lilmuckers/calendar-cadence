import AppKit
import CadenceCore
import CoreBluetooth
import Network
import Observation

/// A phone that has paired with this Mac.
struct PairedPhone: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var lastSeen: Date
    /// Its own key (`CompanionKeys`); nil while it still uses the key older builds shared with every phone.
    var keyID: String? = nil
    /// A key sent to it with `rekey` that it hasn't connected with yet.
    var offeredKeyID: String? = nil
}

/// A phone connected right now.
struct ConnectedPhone: Identifiable, Equatable {
    var id: String
    var name: String
    var displaying: Bool
    /// When it said hello, or last started displaying: the newest one takes the media keys.
    var since = Date()
}

/// The Mac end of the iPhone link: advertises `_cadence._tcp` over Bonjour (Wi-Fi and peer-to-peer),
/// and the Cadence Bluetooth service as a last resort for phones the network can't reach,
/// accepts phones that hold the link key, mirrors meetings to them, and takes Join/Snooze/Dismiss back.
@MainActor
@Observable
final class CompanionHub {
    private static let pairedKey = "Cadence.companion.paired"
    private static let portKey = "Cadence.companion.port"

    private(set) var phones: [ConnectedPhone] = []
    private(set) var paired: [PairedPhone] =
        (UserDefaults.standard.data(forKey: CompanionHub.pairedKey)).flatMap { try? JSONDecoder().decode([PairedPhone].self, from: $0) } ?? []
    private(set) var listening = false
    private(set) var lastError: String?

    /// True while a connected phone is in the foreground in desk mode: the Mac goes quiet.
    var phoneDisplaying: Bool { phones.contains(where: \.displaying) }
    var isConnected: Bool { !phones.isEmpty }

    /// With several phones connected, the one the Mac's media keys, mini-player and volume follow:
    /// the one that most recently went on display, else the one that most recently connected.
    var remotePhone: ConnectedPhone? {
        phones.filter(\.displaying).max { $0.since < $1.since } ?? phones.max { $0.since < $1.since }
    }

    @ObservationIgnored let macID = CompanionIdentity.deviceID("Cadence.companion.macID")
    @ObservationIgnored var macName: String { Host.current().localizedName ?? "Mac" }

    @ObservationIgnored var snapshot: (() -> CompanionSnapshot)?
    @ObservationIgnored var onJoin: ((String) -> Void)?
    @ObservationIgnored var onSnooze: ((String, TimeInterval) -> Void)?
    @ObservationIgnored var onDismiss: ((String) -> Void)?
    @ObservationIgnored var onRSVP: ((String, RSVP?) -> Void)?
    @ObservationIgnored var onInviteLater: ((String) -> Void)?
    @ObservationIgnored var onResolveClash: ((String, String?) -> Void)?
    @ObservationIgnored var onEnrichmentAction: ((String, EnrichmentAction) -> Void)?
    /// What's playing on the Mac, sent to a phone when it says hello.
    @ObservationIgnored var macMedia: (() -> CompanionMedia?)?
    /// What's playing on the phone changed (nil = nothing, or the phone went away).
    @ObservationIgnored var onPhoneMedia: ((CompanionMedia?) -> Void)?
    /// The phone's media volume changed (level 0...1, muted by Cadence).
    @ObservationIgnored var onPhoneVolume: ((Double, Bool) -> Void)?
    /// When a phone that has said hello last sent anything. Channels ping every few seconds, and
    /// pings never reach `handle`, so this asks the channels themselves.
    var lastHeard: Date? {
        channels.values.filter { $0.phoneID != nil }.map(\.channel.lastHeard).max()
    }
    /// The phone's controls, aimed at the Mac's player.
    @ObservationIgnored var onMediaCommand: ((MediaCommand) -> Void)?
    /// A phone paired with several Macs asked this one to open a meeting from another Mac.
    @ObservationIgnored var onJoinMeeting: ((Meeting) -> Void)?
    /// What each connected phone last said is playing (and its volume), so switching which phone
    /// has the remote shows the right one straight away.
    @ObservationIgnored private var phoneMedia: [String: CompanionMedia] = [:]
    @ObservationIgnored private var phoneVolume: [String: (level: Double, muted: Bool)] = [:]
    @ObservationIgnored private var reportedRemoteID: String?
    /// A phone said hello (so it's ready for prompts).
    @ObservationIgnored var onPhoneConnected: (() -> Void)?
    /// The last connected phone went away.
    @ObservationIgnored var onPhonesGone: (() -> Void)?
    /// A phone started or stopped showing its desk display.
    @ObservationIgnored var onDisplayChanged: (() -> Void)?

    @ObservationIgnored private var listener: NWListener?
    /// Bluetooth LE, for phones the network can't reach (`BluetoothAdvertiser`). Created the first
    /// time it's needed, since that's when macOS asks for Bluetooth access.
    @ObservationIgnored private var bluetooth: BluetoothAdvertiser?
    /// The user's "Use Bluetooth when Wi-Fi can't connect" setting.
    var bluetoothEnabled = true {
        didSet { if bluetoothEnabled != oldValue { updateBluetooth() } }
    }
    /// Whether phones can reach this Mac over Bluetooth right now, for the settings.
    private(set) var bluetoothStatus: BluetoothStatus = .off
    enum BluetoothStatus: Equatable {
        case off, notAllowed, bluetoothOff, advertising
    }
    @ObservationIgnored private var started = false
    /// Waiting for the old listener to let go of the port before starting one with the new keys.
    @ObservationIgnored private var restarting = false
    /// The pairing code on show: its key works once, until `CompanionKeys.inviteLifetime`.
    @ObservationIgnored private var pending: (keyID: String, key: Data, expires: Date)?
    @ObservationIgnored private var pendingExpiry: Timer?
    /// The key id of the pairing code on show, nil once it's used, cancelled or expired.
    private(set) var pendingKeyID: String?
    @ObservationIgnored private var channels: [ObjectIdentifier: (channel: CompanionChannel, phoneID: String?)] = [:]
    /// What's gone over the link with each phone since Cadence opened (Settings → iPhone → Advanced).
    let traffic = LinkTrafficStore()
    /// Traffic on a channel before its phone has said who it is; it joins that phone's log after
    /// the hello, or is dropped if the hello fails.
    @ObservationIgnored private var unclaimedTraffic: [ObjectIdentifier: [(kind: String, direction: LinkDirection, bytes: Int, at: Date, over: CompanionTransportKind)]] = [:]
    @ObservationIgnored private var refresher: Timer?
    @ObservationIgnored private var retry: Timer?

    // MARK: Lifecycle

    /// Starts listening if a phone has ever been paired (or a pairing invite is showing).
    func start() {
        let keys = listenerKeys()
        guard listener == nil, !restarting, !keys.isEmpty else { return }
        started = true
        updateBluetooth()
        do {
            // A fixed port, so the address in the pairing code keeps working across launches.
            let port = NWEndpoint.Port(rawValue: Self.port) ?? .any
            let listener: NWListener
            if let fixed = try? NWListener(using: CompanionNetwork.parameters(keys: keys), on: port) {
                listener = fixed
            } else {
                listener = try NWListener(using: CompanionNetwork.parameters(keys: keys))
            }
            var txt = NWTXTRecord()
            txt[CompanionService.macIDKey] = macID
            listener.service = NWListener.Service(name: macName, type: CompanionService.type, domain: nil, txtRecord: txt)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(NetworkTransport(connection: connection)) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
        refresher?.invalidate()
        refresher = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushSnapshot() }
        }
    }

    /// The set of keys changed: start a listener that holds the new set. Connections already made
    /// carry on; the new listener waits for the old one to free the port (binding it straight away fails).
    private func restartListener() {
        guard let old = listener else { return }
        listener = nil
        restarting = true
        old.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, case .cancelled = state, self.restarting else { return }
                self.restarting = false
                self.listening = false
                self.start()
            }
        }
        old.cancel()
    }

    /// Every key a phone may connect with: each paired phone's (and any it was just sent), the
    /// pairing code on show, and the old shared key while a phone still uses it.
    private func listenerKeys() -> [(identity: String, key: Data)] {
        var out: [(identity: String, key: Data)] = []
        if let legacy = CompanionIdentity.storedKey() { out.append((CompanionKeys.legacyIdentity, legacy)) }
        for phone in paired {
            for keyID in [phone.keyID, phone.offeredKeyID].compactMap({ $0 }) {
                if let key = Self.phoneKey(keyID) { out.append((CompanionKeys.identity(for: keyID), key)) }
            }
        }
        if let pending, pending.expires > Date() { out.append((CompanionKeys.identity(for: pending.keyID), pending.key)) }
        return out
    }

    private static func keyAccount(_ keyID: String) -> String { "companion.phoneKey.\(keyID)" }
    private static func phoneKey(_ keyID: String) -> Data? { CompanionIdentity.storedKey(keyAccount(keyID)) }
    private static func storePhoneKey(_ key: Data?, _ keyID: String) { CompanionIdentity.store(key: key, keyAccount(keyID)) }

    func stop() {
        restarting = false
        started = false
        updateBluetooth()
        for (_, entry) in channels { entry.channel.send(.bye(reason: "stopped")); entry.channel.close() }
        channels = [:]
        phones = []
        phoneMedia = [:]
        phoneVolume = [:]
        remoteChanged()
        listener?.cancel()
        listener = nil
        listening = false
        refresher?.invalidate()
        retry?.invalidate()
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            listening = true
            lastError = nil
            if let port = listener?.port?.rawValue, port != Self.port {
                UserDefaults.standard.set(Int(port), forKey: Self.portKey)
            }
        case .failed(let error):
            listening = false
            lastError = error.localizedDescription
            // The saved port may be taken; let the next attempt pick a free one.
            if case .posix(.EADDRINUSE) = error { UserDefaults.standard.removeObject(forKey: Self.portKey) }
            listener?.cancel()
            listener = nil
            // Network changes can kill the listener; try again shortly.
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
        case .cancelled:
            listening = false
        default:
            break
        }
    }

    // MARK: Bluetooth

    /// Advertises over Bluetooth while the hub is listening and the setting is on. Before macOS has
    /// asked about Bluetooth access, waits for a pairing code to be on show, or a phone to connect
    /// (one paired before Bluetooth came along), to start and so ask.
    private func updateBluetooth() {
        let authorization = BluetoothAdvertiser.authorization
        let want = started && bluetoothEnabled && authorization != .denied && authorization != .restricted
            && (authorization == .allowedAlways || pending != nil || !phones.isEmpty)
        if want {
            if bluetooth == nil {
                let advertiser = BluetoothAdvertiser(macID: macID) { [weak self] in self?.listenerKeys() ?? [] }
                advertiser.onChannel = { [weak self] transport in self?.accept(transport) }
                advertiser.onStateChanged = { [weak self] in self?.refreshBluetoothStatus() }
                bluetooth = advertiser
            }
            bluetooth?.start()
        } else {
            bluetooth?.stop()
        }
        refreshBluetoothStatus()
    }

    private func refreshBluetoothStatus() {
        let authorization = BluetoothAdvertiser.authorization
        bluetoothStatus = if !started || !bluetoothEnabled {
            .off
        } else if authorization == .denied || authorization == .restricted {
            .notAllowed
        } else if bluetooth?.isAdvertising == true {
            .advertising
        } else if bluetooth?.state == .poweredOff {
            .bluetoothOff
        } else {
            .off
        }
    }

    // MARK: Pairing

    /// A new pairing code to show as a QR code: a fresh key for one phone, which stops working once a
    /// phone pairs with it, a newer code is shown, it's cancelled or `CompanionKeys.inviteLifetime` passes.
    func invite() -> PairingInvite {
        let keyID = CompanionKeys.newKeyID()
        let key = PairingInvite.newKey()
        setPending((keyID, key, Date().addingTimeInterval(CompanionKeys.inviteLifetime)))
        pendingExpiry = Timer.scheduledTimer(withTimeInterval: CompanionKeys.inviteLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelInvite() }
        }
        if listener == nil { start() } else { restartListener() }
        // Showing a pairing code is when macOS may ask for Bluetooth access, not at launch.
        updateBluetooth()
        return PairingInvite(macID: macID, macName: macName, key: key, keyID: keyID, hosts: Self.lanAddresses(), port: Self.port)
    }

    /// The pairing code was closed without being used: its key stops working.
    func cancelInvite() {
        guard pending != nil else { return }
        setPending(nil)
        restartListener()
    }

    private func setPending(_ value: (keyID: String, key: Data, expires: Date)?) {
        pendingExpiry?.invalidate()
        pendingExpiry = nil
        pending = value
        pendingKeyID = value?.keyID
    }

    /// The port the listener binds to: the one it used last time, else a random one from the dynamic range.
    private static var port: UInt16 {
        if let saved = UserDefaults.standard.object(forKey: portKey) as? Int, let p = UInt16(exactly: saved), p > 0 { return p }
        let p = UInt16.random(in: 49152...65000)
        UserDefaults.standard.set(Int(p), forKey: portKey)
        return p
    }

    /// This Mac's IPv4 addresses on Wi-Fi/Ethernet (en*), for the phone to dial when Bonjour can't find us.
    static func lanAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [String] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: ifa.pointee.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254."), !out.contains(ip) { out.append(ip) }
        }
        return out
    }

    /// Unpairs one phone: its key is deleted, so it can't connect again until it's paired anew. A
    /// phone still on the old shared key takes that key with it (any other phone still on it re-pairs).
    func forget(_ phoneID: String) {
        guard let phone = paired.first(where: { $0.id == phoneID }) else { return }
        for keyID in [phone.keyID, phone.offeredKeyID].compactMap({ $0 }) { Self.storePhoneKey(nil, keyID) }
        if phone.keyID == nil { CompanionIdentity.store(key: nil) }
        paired.removeAll { $0.id == phoneID }
        savePaired()
        for (_, entry) in channels where entry.phoneID == phoneID {
            entry.channel.send(.bye(reason: "This iPhone was unpaired on the Mac."))
            entry.channel.close()
        }
        traffic.reset(phoneID)
        if listenerKeys().isEmpty { stop() } else { restartListener() }
    }

    /// Unpairs every phone: every key goes, so phones keep nothing that still works.
    func forgetAllPhones() {
        stop()
        CompanionIdentity.store(key: nil)
        for phone in paired {
            for keyID in [phone.keyID, phone.offeredKeyID].compactMap({ $0 }) { Self.storePhoneKey(nil, keyID) }
        }
        setPending(nil)
        paired = []
        savePaired()
    }

    private func savePaired() {
        if let data = try? JSONEncoder().encode(paired) { UserDefaults.standard.set(data, forKey: Self.pairedKey) }
    }

    // MARK: Connections

    private func accept(_ transport: CompanionTransport) {
        let channel = CompanionChannel(transport: transport)
        let id = ObjectIdentifier(channel)
        channels[id] = (channel, nil)
        channel.onMessage = { [weak self] message in self?.handle(message, from: id) }
        let kind = transport.kind
        channel.onTraffic = { [weak self] message, direction, bytes in
            guard let self else { return }
            if let phoneID = self.channels[id]?.phoneID {
                self.traffic.record(kind: message.kind, direction, bytes: bytes, peer: phoneID, over: kind)
            } else {
                self.unclaimedTraffic[id, default: []].append((message.kind, direction, bytes, Date(), kind))
            }
        }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            let phoneID = self.channels[id]?.phoneID
            self.channels[id] = nil
            self.unclaimedTraffic[id] = nil
            if let phoneID, !self.channels.values.contains(where: { $0.phoneID == phoneID }) {
                self.phones.removeAll { $0.id == phoneID }
                self.phoneMedia[phoneID] = nil
                self.phoneVolume[phoneID] = nil
                self.remoteChanged()
                if self.phones.isEmpty { self.onPhonesGone?() }
            }
        }
        channel.start()
    }

    private func handle(_ message: CompanionMessage, from id: ObjectIdentifier) {
        guard let entry = channels[id] else { return }
        // Nothing counts until the phone has said who it is and proved which key it holds.
        if entry.phoneID == nil { guard case .hello = message else { return } }
        switch message {
        case .hello(let hello):
            guard hello.protocolVersion == CompanionService.protocolVersion else {
                entry.channel.send(.bye(reason: "Update Cadence on both devices (protocol \(hello.protocolVersion) vs \(CompanionService.protocolVersion))."))
                entry.channel.close()
                return
            }
            if let bound = entry.phoneID, bound != hello.deviceID {
                entry.channel.close()
                return
            }
            guard let match = authenticate(hello, on: entry.channel) else {
                entry.channel.send(.bye(reason: "This iPhone isn't paired with this Mac any more. Pair it again."))
                entry.channel.close()
                return
            }
            let keysChanged = settleKey(match, for: hello, on: entry.channel)
            channels[id]?.phoneID = hello.deviceID
            for event in unclaimedTraffic.removeValue(forKey: id) ?? [] {
                traffic.record(kind: event.kind, event.direction, bytes: event.bytes, at: event.at, peer: hello.deviceID, over: event.over)
            }
            // A repeat hello (the phone was renamed) keeps its place in the media-key queue.
            let known = phones.first { $0.id == hello.deviceID }
            upsertPhone(ConnectedPhone(id: hello.deviceID, name: hello.label, displaying: hello.displaying,
                                       since: known?.since ?? Date()))
            remoteChanged()
            if let i = paired.firstIndex(where: { $0.id == hello.deviceID }) {
                paired[i].name = hello.label
                paired[i].lastSeen = Date()
            } else {
                paired.append(PairedPhone(id: hello.deviceID, name: hello.label, lastSeen: Date()))
            }
            savePaired()
            entry.channel.send(.welcome(macID: macID, macName: macName))
            entry.channel.send(.features([CompanionFeature.joinMeeting.rawValue]))
            if let port = listener?.port?.rawValue {
                entry.channel.send(.address(hosts: Self.lanAddresses(), port: port))
            }
            if let snapshot = snapshot?() { entry.channel.send(.snapshot(snapshot)) }
            if let media = macMedia?() { entry.channel.send(.media(media)) }
            onPhoneConnected?()
            if keysChanged { restartListener() }
            // A phone paired before Bluetooth came along: now's the moment to ask about Bluetooth.
            if BluetoothAdvertiser.authorization == .notDetermined { updateBluetooth() }
        case .displayState(let displaying):
            guard let phoneID = entry.phoneID, let i = phones.firstIndex(where: { $0.id == phoneID }) else { return }
            if displaying, !phones[i].displaying { phones[i].since = Date() }
            phones[i].displaying = displaying
            remoteChanged()
            onDisplayChanged?()
        case .join(let meetingID):
            onJoin?(meetingID)
            broadcast(.dismissAlert(meetingID: meetingID))
        case .snooze(let meetingID, let seconds):
            onSnooze?(meetingID, seconds)
            broadcast(.dismissAlert(meetingID: meetingID))
        case .dismiss(let meetingID):
            onDismiss?(meetingID)
            broadcast(.dismissAlert(meetingID: meetingID))
        case .rsvp(let meetingID, let reply):
            onRSVP?(meetingID, reply)
        case .inviteLater(let meetingID):
            onInviteLater?(meetingID)
        case .resolveClash(let key, let choice):
            onResolveClash?(key, choice)
        case .enrichmentAction(let meetingID, let action):
            onEnrichmentAction?(meetingID, action)
        case .joinMeeting(let meeting):
            onJoinMeeting?(meeting)
        case .media(let media):
            guard let phoneID = entry.phoneID else { return }
            phoneMedia[phoneID] = media
            if phoneID == remotePhone?.id { onPhoneMedia?(media) }
        case .mediaCommand(let command):
            onMediaCommand?(command)
        case .volume(let level, let muted):
            guard let phoneID = entry.phoneID else { return }
            phoneVolume[phoneID] = (level, muted)
            if phoneID == remotePhone?.id { onPhoneVolume?(level, muted) }
        case .bye:
            entry.channel.close()
        default:
            break
        }
    }

    private enum KeyMatch {
        /// The old shared key; `proven` false for older phones that send no proof.
        case legacy(proven: Bool)
        /// A paired phone's own key (or one it was sent with `rekey`).
        case own(String)
        /// The pairing code on show.
        case invite(String, Data)
    }

    /// Which key this phone connected with, checked against the proof in its hello. Nil = not one of ours.
    private func authenticate(_ hello: CompanionHello, on channel: CompanionChannel) -> KeyMatch? {
        guard let proof = hello.proof else {
            // An older phone, which only knows the shared key. TLS already proved it holds one of the
            // listener's keys; without the shared key it can't be one of these.
            return CompanionIdentity.storedKey() == nil ? nil : .legacy(proven: false)
        }
        guard let binding = channel.sessionBinding() else { return nil }
        guard let keyID = hello.keyID else {
            guard let legacy = CompanionIdentity.storedKey(), CompanionKeys.verify(proof, key: legacy, binding: binding) else { return nil }
            return .legacy(proven: true)
        }
        if let pending, pending.keyID == keyID {
            guard pending.expires > Date(), CompanionKeys.verify(proof, key: pending.key, binding: binding) else { return nil }
            return .invite(keyID, pending.key)
        }
        guard paired.contains(where: { $0.keyID == keyID || $0.offeredKeyID == keyID }),
              let key = Self.phoneKey(keyID), CompanionKeys.verify(proof, key: key, binding: binding) else { return nil }
        return .own(keyID)
    }

    /// Records which key `hello`'s phone now uses: a pairing code becomes its own key (and is used
    /// up), a phone on the shared key is sent one of its own, and the shared key goes once no phone
    /// needs it. Returns whether the listener's set of keys changed.
    private func settleKey(_ match: KeyMatch, for hello: CompanionHello, on channel: CompanionChannel) -> Bool {
        var changed = false
        func entryIndex() -> Int {
            if let i = paired.firstIndex(where: { $0.id == hello.deviceID }) { return i }
            paired.append(PairedPhone(id: hello.deviceID, name: hello.label, lastSeen: Date()))
            return paired.count - 1
        }
        func retire(_ keyID: String?) {
            guard let keyID else { return }
            Self.storePhoneKey(nil, keyID)
            changed = true
        }
        switch match {
        case .invite(let keyID, let key):
            // Re-pairing a phone: its old key goes.
            Self.storePhoneKey(key, keyID)
            let i = entryIndex()
            if paired[i].keyID != keyID { retire(paired[i].keyID) }
            retire(paired[i].offeredKeyID)
            paired[i].keyID = keyID
            paired[i].offeredKeyID = nil
            setPending(nil)
        case .own(let keyID):
            guard let i = paired.firstIndex(where: { $0.keyID == keyID || $0.offeredKeyID == keyID }) else { return false }
            // Reinstalled apps get a new device id but keep their Keychain key.
            paired[i].id = hello.deviceID
            if paired[i].offeredKeyID == keyID {
                retire(paired[i].keyID)
                paired[i].keyID = keyID
                paired[i].offeredKeyID = nil
            }
        case .legacy(let proven):
            let i = entryIndex()
            if proven {
                // Give it a key of its own; it switches on its next connection.
                let keyID = paired[i].offeredKeyID ?? CompanionKeys.newKeyID()
                let key = Self.phoneKey(keyID) ?? {
                    let k = PairingInvite.newKey()
                    Self.storePhoneKey(k, keyID)
                    changed = true
                    return k
                }()
                paired[i].offeredKeyID = keyID
                channel.send(.rekey(keyID: keyID, key: key))
            }
        }
        // Nobody on the shared key any more: it stops working.
        if CompanionIdentity.storedKey() != nil, paired.allSatisfy({ $0.keyID != nil }) {
            CompanionIdentity.store(key: nil)
            changed = true
        }
        return changed
    }

    private func upsertPhone(_ phone: ConnectedPhone) {
        if let i = phones.firstIndex(where: { $0.id == phone.id }) { phones[i] = phone } else { phones.append(phone) }
    }

    /// Which phone has the remote may have changed: replay what that one is playing.
    private func remoteChanged() {
        let remote = remotePhone?.id
        guard remote != reportedRemoteID else { return }
        reportedRemoteID = remote
        onPhoneMedia?(remote.flatMap { phoneMedia[$0] })
        if let remote, let v = phoneVolume[remote] { onPhoneVolume?(v.level, v.muted) }
    }

    /// Sends to the phone the media keys follow (see `remotePhone`).
    func sendToRemotePhone(_ message: CompanionMessage) {
        guard let id = remotePhone?.id else { return }
        for (_, entry) in channels where entry.phoneID == id { entry.channel.send(message) }
    }

    /// Sends to every phone that has said hello.
    func broadcast(_ message: CompanionMessage) {
        for (_, entry) in channels where entry.phoneID != nil { entry.channel.send(message) }
    }

    func pushSnapshot() {
        guard isConnected, let snapshot = snapshot?() else { return }
        broadcast(.snapshot(snapshot))
    }
}
