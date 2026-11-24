import Foundation

/// Decides, for one phone ↔ Mac link, when the phone may use Bluetooth. Bluetooth is the last
/// resort: the network (Bonjour, then the saved addresses) always goes first, and keeps being tried
/// while the link is on Bluetooth so it can move back.
///
/// The phone falls back to Bluetooth when one of these is true:
/// - a whole network round failed: Bonjour found nothing usable and every saved address was dialled;
/// - there's been no Wi-Fi or wired network for `grace`;
/// - Local Network access has been denied for `grace`.
///
/// Once a network channel connects, Bluetooth stops and a Bluetooth channel is dropped.
/// Pure value type: the caller feeds it events and the time, and follows `wantsBluetooth`,
/// `shouldDropBluetooth` and `nextDeadline`.
public struct TransportPlanner: Equatable, Sendable {
    /// How long Wi-Fi can be gone (or Local Network access off) before Bluetooth starts, in case
    /// it's only reconnecting.
    public static let grace: TimeInterval = 3

    /// The user's setting and the Bluetooth permission. Off = network only.
    public var bluetoothAllowed: Bool
    public private(set) var running = false
    /// Channels that are up right now (both, briefly, while moving between them).
    public private(set) var connected: Set<CompanionTransportKind> = []

    private var networkRoundFailed = false
    private var noLocalNetworkSince: Date?
    private var localNetworkDeniedSince: Date?

    public init(bluetoothAllowed: Bool = true) {
        self.bluetoothAllowed = bluetoothAllowed
    }

    // MARK: Events

    /// The link started looking for its Mac: the network gets a fresh round first.
    public mutating func start() {
        running = true
        networkRoundFailed = false
    }

    public mutating func stop() {
        running = false
        connected = []
        networkRoundFailed = false
    }

    /// The phone's network path changed. `hasLocalNetwork` = it has Wi-Fi or a wired network, so
    /// Bonjour and peer-to-peer Wi-Fi can work. Coming back onto a network gives it a fresh round.
    public mutating func pathChanged(hasLocalNetwork: Bool, now: Date) {
        if hasLocalNetwork {
            if noLocalNetworkSince != nil { networkRoundFailed = false }
            noLocalNetworkSince = nil
        } else if noLocalNetworkSince == nil {
            noLocalNetworkSince = now
        }
    }

    /// Local Network access for the app was turned off (or back on, which gives the network a fresh round).
    public mutating func localNetworkAccess(denied: Bool, now: Date) {
        if denied {
            if localNetworkDeniedSince == nil { localNetworkDeniedSince = now }
        } else {
            if localNetworkDeniedSince != nil { networkRoundFailed = false }
            localNetworkDeniedSince = nil
        }
    }

    /// Bonjour found nothing usable and every saved address has had its dial this round.
    public mutating func networkRoundFailedToConnect() {
        guard running else { return }
        networkRoundFailed = true
    }

    /// A channel over `kind` was welcomed by the Mac.
    public mutating func connected(_ kind: CompanionTransportKind) {
        guard running else { return }
        connected.insert(kind)
        if kind == .network { networkRoundFailed = false }
    }

    public mutating func disconnected(_ kind: CompanionTransportKind) {
        connected.remove(kind)
    }

    // MARK: Decisions

    /// Whether the phone should be scanning for, connecting to or staying on Bluetooth now.
    /// Network attempts carry on regardless.
    public func wantsBluetooth(now: Date) -> Bool {
        guard running, bluetoothAllowed, !connected.contains(.network) else { return false }
        if connected.contains(.bluetooth) || networkRoundFailed { return true }
        return [noLocalNetworkSince, localNetworkDeniedSince].contains { since in
            since.map { now.timeIntervalSince($0) >= Self.grace } ?? false
        }
    }

    /// A network channel is up alongside a Bluetooth one: drop Bluetooth.
    public var shouldDropBluetooth: Bool {
        connected.contains(.network) && connected.contains(.bluetooth)
    }

    /// When `wantsBluetooth` may next change by itself (a grace period ending), for the caller's
    /// timer. Nil = only events change it.
    public func nextDeadline(after now: Date) -> Date? {
        guard running, bluetoothAllowed, !wantsBluetooth(now: now), !connected.contains(.network) else { return nil }
        return [noLocalNetworkSince, localNetworkDeniedSince]
            .compactMap { $0?.addingTimeInterval(Self.grace) }
            .filter { $0 > now }
            .min()
    }
}
