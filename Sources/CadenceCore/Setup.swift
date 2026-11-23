import Foundation

/// The alert settings a first-run preset touches. Everything else in Settings → Alerts is left alone.
public struct AlertSettings: Equatable, Sendable {
    public var takeoverEnabled: Bool
    public var takeoverLeadSeconds: Double
    /// Minutes after the start an ignored full-screen alert closes itself; 0 = stays until you act.
    public var takeoverAutoDismissMinutes: Int
    public var headsUpEnabled: Bool
    public var headsUpMinutes: Int

    public init(takeoverEnabled: Bool, takeoverLeadSeconds: Double, takeoverAutoDismissMinutes: Int,
                headsUpEnabled: Bool, headsUpMinutes: Int) {
        self.takeoverEnabled = takeoverEnabled
        self.takeoverLeadSeconds = takeoverLeadSeconds
        self.takeoverAutoDismissMinutes = takeoverAutoDismissMinutes
        self.headsUpEnabled = headsUpEnabled
        self.headsUpMinutes = headsUpMinutes
    }
}

/// Starting points for how loud Cadence is, offered during setup. Fine-tuning lives in Settings → Alerts.
public enum AlertPreset: String, CaseIterable, Identifiable, Sendable {
    /// A notification a couple of minutes before, nothing full screen.
    case gentle
    /// The full-screen alert 30 seconds before (Cadence's defaults).
    case normal
    /// A notification 5 minutes before, then a full-screen alert a minute before that stays until you act.
    case insistent

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .gentle: "Gentle"
        case .normal: "Normal"
        case .insistent: "Never let me be late"
        }
    }

    public var detail: String {
        switch self {
        case .gentle: "A notification 2 minutes before. Nothing full screen."
        case .normal: "A full-screen alert 30 seconds before, gone 5 minutes after the start."
        case .insistent: "A notification 5 minutes before, then a full-screen alert a minute before that stays until you act."
        }
    }

    public var symbol: String {
        switch self {
        case .gentle: "leaf"
        case .normal: "bell"
        case .insistent: "alarm"
        }
    }

    /// Whether this preset ever covers the screen.
    public var takesOverScreen: Bool { settings.takeoverEnabled }

    public var settings: AlertSettings {
        switch self {
        case .gentle:
            AlertSettings(takeoverEnabled: false, takeoverLeadSeconds: 30, takeoverAutoDismissMinutes: 5,
                          headsUpEnabled: true, headsUpMinutes: 2)
        case .normal:
            AlertSettings(takeoverEnabled: true, takeoverLeadSeconds: 30, takeoverAutoDismissMinutes: 5,
                          headsUpEnabled: false, headsUpMinutes: 5)
        case .insistent:
            AlertSettings(takeoverEnabled: true, takeoverLeadSeconds: 60, takeoverAutoDismissMinutes: 0,
                          headsUpEnabled: true, headsUpMinutes: 5)
        }
    }

    /// The preset these settings are, or nil when they've been tuned by hand. Settings a preset turns
    /// off (the lead time of a full-screen alert that never shows) don't count.
    public static func matching(_ s: AlertSettings) -> AlertPreset? {
        allCases.first { preset in
            let p = preset.settings
            guard s.takeoverEnabled == p.takeoverEnabled, s.headsUpEnabled == p.headsUpEnabled else { return false }
            if p.takeoverEnabled, s.takeoverLeadSeconds != p.takeoverLeadSeconds
                || s.takeoverAutoDismissMinutes != p.takeoverAutoDismissMinutes { return false }
            if p.headsUpEnabled, s.headsUpMinutes != p.headsUpMinutes { return false }
            return true
        }
    }
}

/// What's left after setup: the steps that were skipped, shown as a checklist in the menu.
public enum SetupTask: String, CaseIterable, Identifiable, Sendable {
    case connectCalendar
    case allowNotifications

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .connectCalendar: "Connect a calendar"
        case .allowNotifications: "Allow notifications"
        }
    }

    /// The tasks still open, in setup order. A calendar counts as connected once any source has
    /// calendars. Notifications count as open only while macOS hasn't asked yet or they're off;
    /// nil means not known yet (no task).
    public static func open(hasCalendars: Bool, notificationsAllowed: Bool?) -> [SetupTask] {
        var tasks: [SetupTask] = []
        if !hasCalendars { tasks.append(.connectCalendar) }
        if notificationsAllowed == false { tasks.append(.allowNotifications) }
        return tasks
    }
}
