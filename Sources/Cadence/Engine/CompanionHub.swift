import AppKit
import CadenceCore
import Network
import Observation

/// A phone that has paired with this Mac (it knows the link key).
struct PairedPhone: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var lastSeen: Date
}

/// A phone connected right now.
struct ConnectedPhone: Identifiable, Equatable {
    var id: String
    var name: String
    var displaying: Bool
}

/// The Mac end of the iPhone link: advertises `_cadence._tcp` over Bonjour (Wi-Fi and peer-to-peer),
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

    @ObservationIgnored let macID = CompanionIdentity.deviceID("Cadence.companion.macID")
    @ObservationIgnored var macName: String { Host.current().localizedName ?? "Mac" }

    @ObservationIgnored var snapshot: (() -> CompanionSnapshot)?
    @ObservationIgnored var onJoin: ((String) -> Void)?
    @ObservationIgnored var onSnooze: ((String, TimeInterval) -> Void)?
    @ObservationIgnored var onDismiss: ((String) -> Void)?
    @ObservationIgnored var onRSVP: ((String, RSVP?) -> Void)?
    @ObservationIgnored var onInviteLater: ((String) -> Void)?
    @ObservationIgnored var onResolveClash: ((String, String?) -> Void)?
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
    /// A phone said hello (so it's ready for prompts).
    @ObservationIgnored var onPhoneConnected: (() -> Void)?
    /// The last connected phone went away.
    @ObservationIgnored var onPhonesGone: (() -> Void)?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var channels: [ObjectIdentifier: (channel: CompanionChannel, phoneID: String?)] = [:]
    @ObservationIgnored private var refresher: Timer?
    @ObservationIgnored private var retry: Timer?

    // MARK: Lifecycle

    /// Starts listening if a phone has ever been paired (or a pairing invite is showing).
    func start() {
        guard listener == nil, let key = CompanionIdentity.storedKey() else { return }
        do {
            // A fixed port, so the address in the pairing code keeps working across launches.
            let port = NWEndpoint.Port(rawValue: Self.port) ?? .any
            let listener: NWListener
            if let fixed = try? NWListener(using: CompanionNetwork.parameters(key: key), on: port) {
                listener = fixed
            } else {
                listener = try NWListener(using: CompanionNetwork.parameters(key: key))
            }
            var txt = NWTXTRecord()
            txt[CompanionService.macIDKey] = macID
            listener.service = NWListener.Service(name: macName, type: CompanionService.type, domain: nil, txtRecord: txt)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
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

    func stop() {
        for (_, entry) in channels { entry.channel.send(.bye(reason: "stopped")); entry.channel.close() }
        channels = [:]
        phones = []
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

    // MARK: Pairing

    /// The invite to show as a QR code. Creates the link key on first use and starts listening.
    func invite() -> PairingInvite {
        let key = CompanionIdentity.storedKey() ?? {
            let k = PairingInvite.newKey()
            CompanionIdentity.store(key: k)
            return k
        }()
        start()
        return PairingInvite(macID: macID, macName: macName, key: key, hosts: Self.lanAddresses(), port: Self.port)
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

    /// Unpairs every phone by rotating the link key (phones keep nothing that still works).
    func forgetAllPhones() {
        stop()
        CompanionIdentity.store(key: nil)
        paired = []
        savePaired()
    }

    private func savePaired() {
        if let data = try? JSONEncoder().encode(paired) { UserDefaults.standard.set(data, forKey: Self.pairedKey) }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let channel = CompanionChannel(connection: connection)
        let id = ObjectIdentifier(channel)
        channels[id] = (channel, nil)
        channel.onMessage = { [weak self] message in self?.handle(message, from: id) }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            let phoneID = self.channels[id]?.phoneID
            self.channels[id] = nil
            if let phoneID, !self.channels.values.contains(where: { $0.phoneID == phoneID }) {
                self.phones.removeAll { $0.id == phoneID }
                if self.phones.isEmpty {
                    self.onPhoneMedia?(nil)
                    self.onPhonesGone?()
                }
            }
        }
        channel.start()
    }

    private func handle(_ message: CompanionMessage, from id: ObjectIdentifier) {
        guard let entry = channels[id] else { return }
        switch message {
        case .hello(let hello):
            guard hello.protocolVersion == CompanionService.protocolVersion else {
                entry.channel.send(.bye(reason: "Update Cadence on both devices (protocol \(hello.protocolVersion) vs \(CompanionService.protocolVersion))."))
                entry.channel.close()
                return
            }
            channels[id]?.phoneID = hello.deviceID
            upsertPhone(ConnectedPhone(id: hello.deviceID, name: hello.label, displaying: hello.displaying))
            if let i = paired.firstIndex(where: { $0.id == hello.deviceID }) {
                paired[i].name = hello.label
                paired[i].lastSeen = Date()
            } else {
                paired.append(PairedPhone(id: hello.deviceID, name: hello.label, lastSeen: Date()))
            }
            savePaired()
            entry.channel.send(.welcome(macID: macID, macName: macName))
            if let port = listener?.port?.rawValue {
                entry.channel.send(.address(hosts: Self.lanAddresses(), port: port))
            }
            if let snapshot = snapshot?() { entry.channel.send(.snapshot(snapshot)) }
            if let media = macMedia?() { entry.channel.send(.media(media)) }
            onPhoneConnected?()
        case .displayState(let displaying):
            guard let phoneID = entry.phoneID, let i = phones.firstIndex(where: { $0.id == phoneID }) else { return }
            phones[i].displaying = displaying
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
        case .media(let media):
            onPhoneMedia?(media)
        case .mediaCommand(let command):
            onMediaCommand?(command)
        case .volume(let level, let muted):
            onPhoneVolume?(level, muted)
        case .bye:
            entry.channel.close()
        default:
            break
        }
    }

    private func upsertPhone(_ phone: ConnectedPhone) {
        if let i = phones.firstIndex(where: { $0.id == phone.id }) { phones[i] = phone } else { phones.append(phone) }
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
