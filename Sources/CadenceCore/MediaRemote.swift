import Foundation

/// When the Mac's media keys go to the phone instead (Settings → Music → Media remote control).
/// Anything that doesn't hold means the key is left alone: the Mac behaves exactly as normal.
public enum MediaRemoteGate {
    /// The phone has to have been heard from this recently: it pings every few seconds.
    public static let freshness: TimeInterval = 12

    public struct Input: Equatable, Sendable {
        public var enabled: Bool
        /// A connected phone is on screen in desk mode.
        public var phoneDisplaying: Bool
        /// When the phone last sent anything.
        public var lastHeard: Date?
        /// Something on the Mac is using the microphone (a call).
        public var onCall: Bool
        /// The phone is playing right now.
        public var phonePlaying: Bool
        /// When the phone last stopped playing (nil = not played since connecting).
        public var phoneStoppedAt: Date?
        /// Stop taking the keys this long after the phone pauses; nil = keep taking them for as
        /// long as the phone shows its desk display.
        public var pauseLimit: TimeInterval?

        public init(enabled: Bool, phoneDisplaying: Bool, lastHeard: Date?, onCall: Bool,
                    phonePlaying: Bool, phoneStoppedAt: Date?, pauseLimit: TimeInterval?) {
            self.enabled = enabled
            self.phoneDisplaying = phoneDisplaying
            self.lastHeard = lastHeard
            self.onCall = onCall
            self.phonePlaying = phonePlaying
            self.phoneStoppedAt = phoneStoppedAt
            self.pauseLimit = pauseLimit
        }
    }

    /// The phone is there to take a key at all (before thinking about what's playing).
    public static func phoneReady(_ i: Input, now: Date) -> Bool {
        guard i.enabled, i.phoneDisplaying, !i.onCall, let heard = i.lastHeard else { return false }
        return now.timeIntervalSince(heard) < freshness
    }

    /// Send the media keys to the phone.
    public static func intercepts(_ i: Input, now: Date) -> Bool {
        guard phoneReady(i, now: now) else { return false }
        guard let limit = i.pauseLimit else { return true }
        if i.phonePlaying { return true }
        guard let stopped = i.phoneStoppedAt else { return false }
        return now.timeIntervalSince(stopped) < limit
    }
}

/// When the Mac's mini-player for the phone shows.
public enum MediaHUDMode: String, Codable, CaseIterable, Sendable {
    case never, onKeys, always

    public var label: String {
        switch self {
        case .never: "Never"
        case .onKeys: "When I use the media keys"
        case .always: "Always while the phone is in desk mode"
        }
    }
}

public enum MediaVolume {
    /// iOS and macOS both step volume in sixteenths.
    public static let step = 1.0 / 16

    public static func stepped(_ level: Double, up: Bool) -> Double {
        let steps = (level / step).rounded()
        return min(1, max(0, (steps + (up ? 1 : -1)) * step))
    }
}
