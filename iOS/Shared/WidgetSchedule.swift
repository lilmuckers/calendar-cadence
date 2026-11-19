import Foundation

/// One meeting as the Home and Lock Screen widgets see it. The widget extension doesn't link
/// CadenceCore, so the app flattens `Meeting` into this.
struct WidgetMeeting: Codable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var red: Double
    var green: Double
    var blue: Double
    var hasLink: Bool

    /// Opens Cadence and joins (same link as the Live Activity).
    var joinURL: URL { URL(string: "cadence-companion://join?id=\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")! }
}

/// The upcoming meetings the app hands to the widgets through the App Group. Already filtered:
/// no all-day events, nothing agenda-only or muted by a clash choice.
struct WidgetSchedule: Codable, Equatable {
    var meetings: [WidgetMeeting]
    var generatedAt: Date

    /// Same stages as the Mac's menu bar icon (`IconMood` in CadenceCore).
    static let nervousLead: TimeInterval = 15 * 60
    static let panicLead: TimeInterval = 5 * 60

    /// The next meeting still to start today, if any.
    func next(after now: Date, calendar: Calendar = .current) -> WidgetMeeting? {
        meetings.filter { $0.start > now && calendar.isDate($0.start, inSameDayAs: now) }
            .min { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// The meeting after `meeting` today, for the "then …" line.
    func following(_ meeting: WidgetMeeting, calendar: Calendar = .current) -> WidgetMeeting? {
        meetings.filter { $0.id != meeting.id && $0.start >= meeting.start && calendar.isDate($0.start, inSameDayAs: meeting.start) }
            .min { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    func mood(at now: Date, calendar: Calendar = .current) -> ActivityMood {
        guard let next = next(after: now, calendar: calendar) else { return .calm }
        let remaining = next.start.timeIntervalSince(now)
        if remaining <= Self.panicLead { return .panicking }
        if remaining <= Self.nervousLead { return .nervous }
        return .calm
    }

    /// When the widget has to redraw: now, every meeting start (the next one changes), the icon's
    /// mood switches, and the next midnight (a new day's "next"). The countdown itself is a system
    /// timer, so it ticks between entries on its own. Sorted, unique, none before `now`.
    func entryDates(from now: Date, calendar: Calendar = .current) -> [Date] {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        var dates: Set<Date> = [now, midnight]
        for m in meetings where m.start > now && m.start <= midnight {
            dates.insert(m.start)
            for lead in [Self.nervousLead, Self.panicLead] {
                let at = m.start.addingTimeInterval(-lead)
                if at > now { dates.insert(at) }
            }
        }
        return dates.sorted()
    }

    // MARK: - Storage (App Group defaults)

    static let storageKey = "Cadence.widgets.schedule"

    /// The App Group's defaults, nil if the group isn't set up (e.g. signing without it).
    static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "CadenceAppGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return UserDefaults(suiteName: group)
    }

    static func load(from defaults: UserDefaults? = WidgetSchedule.defaults) -> WidgetSchedule? {
        guard let data = defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSchedule.self, from: data)
    }

    func save(to defaults: UserDefaults? = WidgetSchedule.defaults) {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
