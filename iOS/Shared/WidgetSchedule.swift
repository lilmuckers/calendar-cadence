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

/// A stretch of the working day (`DaySegment` in CadenceCore, flattened for the widgets): before
/// work, focus time, a break, the end of the day.
struct WidgetSegment: Codable, Hashable {
    /// "beforeWork", "focus", "meal", "rest" or "endOfDay".
    var kind: String
    var start: Date
    var end: Date
    var title: String
    var detail: String

    var pose: MascotPose {
        switch kind {
        case "beforeWork": .coffee
        case "focus": .focus
        case "meal": .lunch
        case "endOfDay": .wave
        default: .tea
        }
    }

    /// Worth a countdown: focus and breaks end at a set time you're waiting on.
    var countsDown: Bool { kind == "focus" || kind == "meal" || kind == "rest" }

    func contains(_ date: Date) -> Bool { start <= date && date < end }
}

/// The upcoming meetings the app hands to the widgets through the App Group. Already filtered:
/// no all-day events, nothing agenda-only or muted by a clash choice.
struct WidgetSchedule: Codable, Equatable {
    var meetings: [WidgetMeeting]
    var generatedAt: Date
    /// Hour of the day (0–23) from which, with nothing left today, the widgets show tomorrow's
    /// first meeting instead of "No more meetings today!". nil = never. Optional so schedules saved
    /// before this existed still decode.
    var tomorrowFromHour: Int? = nil
    /// Today's and tomorrow's working-day stretches. Nil with working hours off, or from older builds.
    var segments: [WidgetSegment]? = nil

    /// How often the widget re-reads the saved schedule on its own, in case the app's reload was dropped.
    static let refreshInterval: TimeInterval = 30 * 60

    /// Within this long of the next meeting the widgets show it rather than the day's moment.
    static let momentYield: TimeInterval = 30 * 60

    /// The day's moment to show at `now`: a stretch is on and no meeting is live or close.
    func segment(at now: Date, calendar: Calendar = .current) -> WidgetSegment? {
        guard let seg = segments?.first(where: { $0.contains(now) }) else { return nil }
        if meetings.contains(where: { $0.start <= now && now < $0.end }) { return nil }
        if let next = next(after: now, calendar: calendar), next.start.timeIntervalSince(now) <= Self.momentYield { return nil }
        return seg
    }

    /// Same stages as the Mac's menu bar icon (`IconMood` in CadenceCore).
    static let nervousLead: TimeInterval = 15 * 60
    static let panicLead: TimeInterval = 5 * 60

    /// The next meeting still to start today, if any.
    func next(after now: Date, calendar: Calendar = .current) -> WidgetMeeting? {
        meetings.filter { $0.start > now && calendar.isDate($0.start, inSameDayAs: now) }
            .min { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// How close the next meeting has to be to take over from one in progress (same as the Mac's
    /// panel, `PanelPlanner` in CadenceCore).
    static let liveYield: TimeInterval = 10 * 60

    /// The meeting in progress to show at `now`: the latest to start of those running, unless the
    /// next one starts within `liveYield`. Matches what the app and the Mac show during a meeting.
    func live(at now: Date, calendar: Calendar = .current) -> WidgetMeeting? {
        guard let live = meetings.filter({ $0.start <= now && now < $0.end }).max(by: { ($0.start, $0.title) < ($1.start, $1.title) })
        else { return nil }
        if let next = next(after: now, calendar: calendar), next.start.timeIntervalSince(now) <= Self.liveYield { return nil }
        return live
    }

    /// The meeting after `meeting` today, for the "then …" line.
    func following(_ meeting: WidgetMeeting, calendar: Calendar = .current) -> WidgetMeeting? {
        meetings.filter { $0.id != meeting.id && $0.start >= meeting.start && calendar.isDate($0.start, inSameDayAs: meeting.start) }
            .min { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// Tomorrow's first meeting, once it's `tomorrowFromHour` or later and nothing is left today.
    func tomorrowFirst(after now: Date, calendar: Calendar = .current) -> WidgetMeeting? {
        guard let from = tomorrowStart(on: now, calendar: calendar), now >= from,
              next(after: now, calendar: calendar) == nil,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        return meetings.filter { $0.start > now && calendar.isDate($0.start, inSameDayAs: tomorrow) }
            .min { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// When today the widgets start looking at tomorrow, nil if they don't.
    private func tomorrowStart(on day: Date, calendar: Calendar) -> Date? {
        guard let hour = tomorrowFromHour, (0...23).contains(hour) else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    func mood(at now: Date, calendar: Calendar = .current) -> ActivityMood {
        guard let next = next(after: now, calendar: calendar) else { return .calm }
        let remaining = next.start.timeIntervalSince(now)
        if remaining <= Self.panicLead { return .panicking }
        if remaining <= Self.nervousLead { return .nervous }
        return .calm
    }

    /// When the widget has to redraw: now, every meeting start and end (the next or live one changes), the icon's
    /// mood switches, the evening switch to tomorrow's first meeting, and the next midnight (a new
    /// day's "next"). The countdown itself is a system timer, so it ticks between entries on its own. Sorted, unique, none before `now`.
    func entryDates(from now: Date, calendar: Calendar = .current) -> [Date] {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        var dates: Set<Date> = [now, midnight]
        if let from = tomorrowStart(on: now, calendar: calendar), from > now { dates.insert(from) }
        for seg in segments ?? [] {
            for d in [seg.start, seg.end] where d > now && d <= midnight { dates.insert(d) }
        }
        // With moments to show, also redraw when a meeting takes over from one and hands back.
        for m in meetings where !(segments ?? []).isEmpty {
            for d in [m.start.addingTimeInterval(-Self.momentYield), m.end] where d > now && d <= midnight { dates.insert(d) }
        }
        // A meeting in progress shows until it ends or the next one is close.
        for m in meetings {
            for d in [m.end, m.start.addingTimeInterval(-Self.liveYield)] where d > now && d <= midnight { dates.insert(d) }
        }
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
