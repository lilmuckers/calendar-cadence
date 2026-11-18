import Foundation

/// What the Mac does with the full-screen alert while the iPhone is on the desk showing Cadence.
public enum CompanionTakeoverMode: String, Codable, CaseIterable, Sendable {
    /// Full-screen alert on the Mac as usual, and on the phone.
    case macAndPhone
    /// Only the phone alerts.
    case phoneOnly

    public var label: String {
        switch self {
        case .macAndPhone: "Full-screen on the Mac too"
        case .phoneOnly: "Only on the iPhone"
        }
    }
}

/// Where alerts go when a paired iPhone may be displaying. Only while the phone is connected *and*
/// displaying does the Mac go quiet; otherwise everything is unchanged.
/// While the phone has the alert: show it on the Mac after all once the meeting is this late and
/// still not joined, snoozed or dismissed.
public enum CompanionEscalation: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120

    public var label: String {
        switch self {
        case .off: "Never"
        case .tenSeconds: "After 10 seconds"
        case .thirtySeconds: "After 30 seconds"
        case .oneMinute: "After 1 minute"
        case .twoMinutes: "After 2 minutes"
        }
    }

    /// When to escalate an alert for a meeting starting at `start`, given it was sent at `now`.
    /// Nil = never. An alert that only went out after that point escalates straight away.
    public func date(start: Date, now: Date) -> Date? {
        guard self != .off else { return nil }
        return max(now, start.addingTimeInterval(TimeInterval(rawValue)))
    }
}

public enum CompanionRouting {
    /// Whether the floating countdown panel may show on the Mac.
    public static func macShowsPanel(phoneDisplaying: Bool) -> Bool { !phoneDisplaying }

    /// Whether heads-up / leave / wrap-up / summary notifications show on the Mac.
    public static func macShowsReminders(phoneDisplaying: Bool) -> Bool { !phoneDisplaying }

    /// The Mac's share of a due alert. While the phone displays, only a full-screen alert may stay on
    /// the Mac (if the user wants it); banners and notifications move to the phone.
    public static func macPlan(_ plan: AlertPlan, phoneDisplaying: Bool, mode: CompanionTakeoverMode) -> AlertPlan {
        guard phoneDisplaying else { return plan }
        switch (plan, mode) {
        case (.fullScreen, .macAndPhone): return plan
        default: return .none
        }
    }

    /// Whether a due alert is also sent to the phone. Sent whenever the phone is connected, so a phone
    /// that's displaying shows it even when the Mac skips it (e.g. presenting with "Don't alert").
    public static func sendsToPhone(connected: Bool, phoneDisplaying: Bool) -> Bool { connected && phoneDisplaying }
}

/// What the phone's Join button does.
public enum JoinDestination: Equatable, Sendable {
    case mac, phone

    public static func choose(connectedToMac: Bool) -> JoinDestination { connectedToMac ? .mac : .phone }
}
