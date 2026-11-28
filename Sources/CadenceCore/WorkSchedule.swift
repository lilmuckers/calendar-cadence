import Foundation

/// A break Cadence keeps clear for you every working day (or on chosen days): lunch, a walk, school run.
public struct WorkBreak: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Minutes after midnight.
    public var start: Int
    public var end: Int
    /// `Calendar` weekdays (1 = Sunday … 7 = Saturday) it applies on; nil = every working day.
    public var days: Set<Int>?

    public init(id: String = UUID().uuidString, name: String, start: Int, end: Int, days: Set<Int>? = nil) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.days = days
    }

    public static let lunch = WorkBreak(id: "lunch", name: "Lunch", start: 12 * 60 + 30, end: 13 * 60 + 30)

    /// A lunch-ish break (the mascot eats instead of sipping tea).
    public var isMeal: Bool {
        let n = name.lowercased()
        return ["lunch", "breakfast", "dinner", "brunch", "meal", "food", "eat"].contains { n.contains($0) }
    }
}

/// One weekday's working hours.
public struct WorkDay: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    /// Minutes after midnight.
    public var start: Int
    public var end: Int

    public init(enabled: Bool, start: Int = 9 * 60, end: Int = 17 * 60 + 30) {
        self.enabled = enabled
        self.start = start
        self.end = end
    }
}

/// How Cadence stands up for your breaks and working hours. Each one can be turned off.
public struct BreakDefences: Codable, Equatable, Hashable, Sendable {
    /// Invite cards say when a meeting lands on a break or outside working hours.
    public var flagInvites = true
    /// `find_free_time` never offers break time.
    public var protectInFreeTime = true
    /// A nudge when a break starts.
    public var breakNudge = true
    /// A nudge when the meeting you're in is about to run into a break.
    public var overrunWarning = true
    /// A meeting booked over a break asks, like a double-booking, whether to keep the break.
    public var clashPrompt = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BreakDefences()
        flagInvites = (try? c.decodeIfPresent(Bool.self, forKey: .flagInvites)) ?? d.flagInvites
        protectInFreeTime = (try? c.decodeIfPresent(Bool.self, forKey: .protectInFreeTime)) ?? d.protectInFreeTime
        breakNudge = (try? c.decodeIfPresent(Bool.self, forKey: .breakNudge)) ?? d.breakNudge
        overrunWarning = (try? c.decodeIfPresent(Bool.self, forKey: .overrunWarning)) ?? d.overrunWarning
        clashPrompt = (try? c.decodeIfPresent(Bool.self, forKey: .clashPrompt)) ?? d.clashPrompt
    }
}

/// Working hours per weekday plus daily breaks. Gives the day its shape: before work, focus time,
/// breaks, end of the day.
public struct WorkSchedule: Codable, Equatable, Hashable, Sendable {
    /// Off: Cadence ignores the schedule (no moments, no break defences); find_free_time still uses the hours.
    public var enabled = true
    /// Indexed by `Calendar` weekday - 1 (0 = Sunday … 6 = Saturday). Always 7 entries.
    public var days: [WorkDay] = WorkSchedule.weekdays(start: 9 * 60, end: 17 * 60 + 30)
    public var breaks: [WorkBreak] = [.lunch]
    /// A gap at least this long, with nothing in it, counts as focus time.
    public var focusMinimumMinutes = 45
    public var defences = BreakDefences()

    public init() {}

    public init(days: [WorkDay], breaks: [WorkBreak] = [], focusMinimumMinutes: Int = 45, enabled: Bool = true) {
        self.days = Self.padded(days)
        self.breaks = breaks
        self.focusMinimumMinutes = focusMinimumMinutes
        self.enabled = enabled
    }

    /// Monday to Friday, `start`…`end`.
    public static func weekdays(start: Int, end: Int) -> [WorkDay] {
        (1...7).map { WorkDay(enabled: (2...6).contains($0), start: start, end: end) }
    }

    private static func padded(_ days: [WorkDay]) -> [WorkDay] {
        var out = Array(days.prefix(7))
        let fallback = weekdays(start: 9 * 60, end: 17 * 60 + 30)
        while out.count < 7 { out.append(fallback[out.count]) }
        return out
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WorkSchedule()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        days = Self.padded((try? c.decodeIfPresent([WorkDay].self, forKey: .days)) ?? d.days)
        breaks = (try? c.decodeIfPresent([WorkBreak].self, forKey: .breaks)) ?? d.breaks
        focusMinimumMinutes = (try? c.decodeIfPresent(Int.self, forKey: .focusMinimumMinutes)) ?? d.focusMinimumMinutes
        defences = (try? c.decodeIfPresent(BreakDefences.self, forKey: .defences)) ?? d.defences
    }

    public func day(_ weekday: Int) -> WorkDay { days[(weekday - 1 + 7) % 7] }

    /// Today's working hours, nil on a day off.
    public func hours(on date: Date, calendar: Calendar = .current) -> DateInterval? {
        let wd = day(calendar.component(.weekday, from: date))
        guard wd.enabled, wd.end > wd.start else { return nil }
        let midnight = calendar.startOfDay(for: date)
        return DateInterval(start: Self.at(wd.start, midnight, calendar), end: Self.at(wd.end, midnight, calendar))
    }

    /// The breaks on `date` (working days only), in time order.
    public func breaks(on date: Date, calendar: Calendar = .current) -> [(WorkBreak, DateInterval)] {
        let weekday = calendar.component(.weekday, from: date)
        guard day(weekday).enabled else { return [] }
        let midnight = calendar.startOfDay(for: date)
        return breaks
            .filter { $0.end > $0.start && ($0.days?.contains(weekday) ?? true) }
            .map { ($0, DateInterval(start: Self.at($0.start, midnight, calendar), end: Self.at($0.end, midnight, calendar))) }
            .sorted { $0.1.start < $1.1.start }
    }

    static func at(_ minutes: Int, _ midnight: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .minute, value: minutes, to: midnight) ?? midnight.addingTimeInterval(Double(minutes) * 60)
    }

    /// How a meeting sits against the schedule: on a break, outside hours, on a day off. A meeting
    /// only counts as on a break when it overlaps it by more than `overlapTolerance`.
    public func conflicts(for meeting: Meeting, calendar: Calendar = .current,
                          overlapTolerance: TimeInterval = ClashDetector.defaultOverlapTolerance) -> [WorkConflict] {
        guard enabled, !meeting.isAllDay else { return [] }
        guard let hours = hours(on: meeting.start, calendar: calendar) else { return [.dayOff] }
        var out: [WorkConflict] = []
        for (b, span) in breaks(on: meeting.start, calendar: calendar)
        where ClashDetector.overlaps(meeting.start, meeting.end, span.start, span.end, tolerance: overlapTolerance) {
            out.append(.onBreak(b.name))
        }
        if meeting.start < hours.start || meeting.end > hours.end { out.append(.outsideHours) }
        return out
    }

    /// A stand-in meeting for a break on a given day, so breaks can go through the clash and
    /// reminder machinery. Its id is stable for that day.
    public static func breakMeeting(_ b: WorkBreak, span: DateInterval, calendar: Calendar = .current) -> Meeting {
        let c = calendar.dateComponents([.year, .month, .day], from: span.start)
        let day = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return Meeting(id: "\(breakIDPrefix)\(b.id):\(day)", title: b.name, start: span.start, end: span.end,
                       calendar: breakCalendar, participation: .accepted, availability: .busy)
    }

    public static let breakIDPrefix = "break:"
    public static let breakCalendar = CalendarInfo(id: "cadence.breaks", title: "Break", sourceTitle: "Cadence",
                                                   color: RGBAColor(red: 0.36, green: 0.74, blue: 0.52), kind: .local)

    /// Stand-in meetings for every break from `from` to `to`.
    public func breakMeetings(from: Date, to: Date, calendar: Calendar = .current) -> [Meeting] {
        guard enabled else { return [] }
        var out: [Meeting] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            for (b, span) in breaks(on: day, calendar: calendar) where span.end > from && span.start < to {
                out.append(Self.breakMeeting(b, span: span, calendar: calendar))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }
}

public extension Meeting {
    /// One of Cadence's stand-ins for a break, not a real event.
    var isBreak: Bool { id.hasPrefix(WorkSchedule.breakIDPrefix) }
}

public enum WorkConflict: Equatable, Hashable, Sendable {
    case onBreak(String)
    case outsideHours
    case dayOff

    public var label: String {
        switch self {
        case .onBreak(let name): "Lands on your \(name) break"
        case .outsideHours: "Outside your working hours"
        case .dayOff: "On a non-working day"
        }
    }
}

/// Sum-up of a working day, for "you got 2h 10m of focus time!".
public struct DayRecap: Equatable, Hashable, Codable, Sendable {
    public var meetingCount: Int
    /// Time in meetings within working hours.
    public var meetingMinutes: Int
    /// Clear stretches at least the focus minimum long, added up.
    public var focusMinutes: Int
    public var longestFocusMinutes: Int

    public init(meetingCount: Int, meetingMinutes: Int, focusMinutes: Int, longestFocusMinutes: Int) {
        self.meetingCount = meetingCount
        self.meetingMinutes = meetingMinutes
        self.focusMinutes = focusMinutes
        self.longestFocusMinutes = longestFocusMinutes
    }
}

/// One stretch of the working day worked out ahead, for the widgets and Live Activity.
public struct DaySegment: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case beforeWork, focus, meal, rest, endOfDay
    }

    public var kind: Kind
    public var start: Date
    public var end: Date
    public var title: String
    public var detail: String

    public init(kind: Kind, start: Date, end: Date, title: String, detail: String) {
        self.kind = kind
        self.start = start
        self.end = end
        self.title = title
        self.detail = detail
    }

    public func contains(_ date: Date) -> Bool { start <= date && date < end }
}

/// Where you are in the working day.
public enum DayMoment: Equatable, Sendable {
    /// Before work starts. `first` is the day's first meeting.
    case beforeWork(starts: Date, first: Meeting?)
    /// A clear stretch until `until`; `next` is what ends it (a meeting), nil for a break or the day's end.
    case focus(since: Date, until: Date, next: Meeting?)
    /// A short gap between things: nothing special to say.
    case between(until: Date)
    case onBreak(WorkBreak, ends: Date)
    case inMeeting(Meeting)
    /// Working hours are over.
    case endOfDay(DayRecap)
    case dayOff

    /// A short name for the Live Activity and widgets (which don't link CadenceCore).
    public var kind: String {
        switch self {
        case .beforeWork: "beforeWork"
        case .focus: "focus"
        case .between: "between"
        case .onBreak: "onBreak"
        case .inMeeting: "inMeeting"
        case .endOfDay: "endOfDay"
        case .dayOff: "dayOff"
        }
    }
}

public enum DayPlanner {
    /// The meetings that take up your time: timed, not cancelled, declined, free or Cadence's own breaks.
    static func busy(_ meetings: [Meeting]) -> [Meeting] {
        meetings.filter { !$0.isAllDay && !$0.isCanceled && $0.participation != .declined && $0.availability != .free && !$0.isBreak }
            .sorted { $0.start < $1.start }
    }

    /// Where `now` falls in the day. nil when the schedule is off.
    /// `skipping`: ids of break stand-ins given up for the day (a clash choice).
    public static func moment(meetings: [Meeting], schedule: WorkSchedule, now: Date, skipping: Set<String> = [],
                              calendar: Calendar = .current) -> DayMoment? {
        guard schedule.enabled else { return nil }
        let busy = busy(meetings).filter { calendar.isDate($0.start, inSameDayAs: now) || $0.isInProgress(at: now) }
        if let live = busy.last(where: { $0.isInProgress(at: now) }) { return .inMeeting(live) }
        guard let hours = schedule.hours(on: now, calendar: calendar) else { return .dayOff }
        if now < hours.start {
            return .beforeWork(starts: hours.start, first: busy.first { $0.start >= now })
        }
        if now >= hours.end { return .endOfDay(recap(meetings: meetings, schedule: schedule, day: now, calendar: calendar)) }
        let breaks = schedule.breaks(on: now, calendar: calendar)
            .filter { !skipping.contains(WorkSchedule.breakMeeting($0.0, span: $0.1, calendar: calendar).id) }
        if let (b, span) = breaks.first(where: { $0.1.contains(now) && now < $0.1.end }) { return .onBreak(b, ends: span.end) }

        // The clear stretch around now: from the last thing that ended to the next that starts.
        let next = busy.first { $0.start > now }
        let nextBreak = breaks.map(\.1.start).first { $0 > now }
        let until = [next?.start, nextBreak, hours.end].compactMap { $0 }.min() ?? hours.end
        let lastEnd = (busy.map(\.end) + breaks.map(\.1.end)).filter { $0 <= now }.max()
        let since = max(hours.start, lastEnd ?? hours.start)
        let endsWithMeeting = next.map { $0.start <= until } ?? false
        if until.timeIntervalSince(since) >= Double(schedule.focusMinimumMinutes) * 60,
           until.timeIntervalSince(now) >= 5 * 60 {
            return .focus(since: since, until: until, next: endsWithMeeting ? next : nil)
        }
        return .between(until: until)
    }

    /// The day's meetings and focus time, within working hours.
    public static func recap(meetings: [Meeting], schedule: WorkSchedule, day: Date, calendar: Calendar = .current) -> DayRecap {
        let todays = busy(meetings).filter { calendar.isDate($0.start, inSameDayAs: day) }
        guard let hours = schedule.hours(on: day, calendar: calendar) else {
            return DayRecap(meetingCount: todays.count, meetingMinutes: 0, focusMinutes: 0, longestFocusMinutes: 0)
        }
        let meetingSpans = merge(todays.compactMap { clip(DateInterval(start: $0.start, end: max($0.start, $0.end)), to: hours) })
        let meetingMinutes = Int(meetingSpans.reduce(0) { $0 + $1.duration } / 60)
        let blocked = merge(meetingSpans + schedule.breaks(on: day, calendar: calendar).compactMap { clip($0.1, to: hours) })
        let gaps = focusGaps(in: hours, blocked: blocked, minimum: Double(schedule.focusMinimumMinutes) * 60)
        let focus = gaps.map { Int($0.duration / 60) }
        return DayRecap(meetingCount: todays.count, meetingMinutes: meetingMinutes,
                        focusMinutes: focus.reduce(0, +), longestFocusMinutes: focus.max() ?? 0)
    }

    /// The day laid out ahead of time, for widgets that can't work it out themselves: the morning
    /// before work (from `morningLead` before it starts), each focus stretch, each break, and the
    /// evening after work. Meetings and short gaps aren't segments.
    public static func segments(meetings: [Meeting], schedule: WorkSchedule, day: Date, skipping: Set<String> = [],
                                morningLead: TimeInterval = 3 * 3600, calendar: Calendar = .current) -> [DaySegment] {
        guard schedule.enabled else { return [] }
        let midnight = calendar.startOfDay(for: day)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86_400)
        guard let hours = schedule.hours(on: day, calendar: calendar) else { return [] }
        func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
        let todays = busy(meetings).filter { calendar.isDate($0.start, inSameDayAs: day) }
        let breaks = schedule.breaks(on: day, calendar: calendar)
            .filter { !skipping.contains(WorkSchedule.breakMeeting($0.0, span: $0.1, calendar: calendar).id) }
        var out: [DaySegment] = []
        let first = todays.first { $0.start >= hours.start }
        out.append(DaySegment(kind: .beforeWork, start: max(midnight, hours.start.addingTimeInterval(-morningLead)), end: hours.start,
                              title: "Morning!", detail: first.map { "First up: \($0.title) at \(time($0.start))" } ?? "Work starts at \(time(hours.start))"))
        let meetingSpans = merge(todays.compactMap { clip(DateInterval(start: $0.start, end: max($0.start, $0.end)), to: hours) })
        let breakSpans = breaks.compactMap { b in clip(b.1, to: hours).map { (b.0, $0) } }
        for (b, span) in breakSpans {
            // A meeting over the break eats into it; what's left still counts.
            out.append(DaySegment(kind: b.isMeal ? .meal : .rest, start: span.start, end: span.end, title: b.name,
                                  detail: "Back at \(time(span.end))"))
        }
        let blocked = merge(meetingSpans + breakSpans.map(\.1))
        for gap in focusGaps(in: hours, blocked: blocked, minimum: Double(schedule.focusMinimumMinutes) * 60) {
            let next = todays.first { abs($0.start.timeIntervalSince(gap.end)) < 1 }
            out.append(DaySegment(kind: .focus, start: gap.start, end: gap.end, title: "Focus time",
                                  detail: next.map { "Clear until \($0.title) at \(time($0.start))" } ?? "Clear until \(time(gap.end))"))
        }
        let recap = recap(meetings: meetings, schedule: schedule, day: day, calendar: calendar)
        let wrap = message(for: .endOfDay(recap), now: hours.end)
        out.append(DaySegment(kind: .endOfDay, start: hours.end, end: nextMidnight, title: wrap.title, detail: wrap.detail))
        return out.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    /// Focus time had so far today: the clear stretches (at least the focus minimum long) up to now.
    public static func focusSoFar(meetings: [Meeting], schedule: WorkSchedule, now: Date, calendar: Calendar = .current) -> Int {
        guard let hours = schedule.hours(on: now, calendar: calendar), now > hours.start else { return 0 }
        let todays = busy(meetings).filter { calendar.isDate($0.start, inSameDayAs: now) }
        let blocked = merge(todays.compactMap { clip(DateInterval(start: $0.start, end: max($0.start, $0.end)), to: hours) }
            + schedule.breaks(on: now, calendar: calendar).compactMap { clip($0.1, to: hours) })
        let gaps = focusGaps(in: hours, blocked: blocked, minimum: Double(schedule.focusMinimumMinutes) * 60)
        let seconds = gaps.reduce(0.0) { sum, g in sum + max(0, min(g.end, now).timeIntervalSince(g.start)) }
        return Int(seconds / 60)
    }

    /// Clear stretches in `hours` at least `minimum` long, around `blocked` (sorted, merged).
    static func focusGaps(in hours: DateInterval, blocked: [DateInterval], minimum: TimeInterval) -> [DateInterval] {
        var out: [DateInterval] = []
        var cursor = hours.start
        for b in blocked {
            if b.start.timeIntervalSince(cursor) >= minimum { out.append(DateInterval(start: cursor, end: b.start)) }
            cursor = max(cursor, b.end)
        }
        if hours.end.timeIntervalSince(cursor) >= minimum { out.append(DateInterval(start: cursor, end: hours.end)) }
        return out
    }

    static func clip(_ span: DateInterval, to hours: DateInterval) -> DateInterval? {
        let s = max(span.start, hours.start), e = min(span.end, hours.end)
        return e > s ? DateInterval(start: s, end: e) : nil
    }

    static func merge(_ spans: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, s.end))
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// "2h 10m", "45m", "1h".
    public static func duration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// What to say for a moment: a headline and a line under it.
    public static func message(for moment: DayMoment, now: Date) -> (title: String, detail: String) {
        func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
        switch moment {
        case .beforeWork(let starts, let first):
            let then = first.map { "First up: \($0.title) at \(time($0.start))" } ?? "No meetings today."
            return ("Morning! Work starts at \(time(starts))", then)
        case .focus(_, let until, let next):
            let left = duration(minutes: max(1, Int(until.timeIntervalSince(now) / 60)))
            let then = next.map { "Clear until \($0.title) at \(time($0.start))" } ?? "Clear until \(time(until))"
            return ("Focus time — \(left) clear", then)
        case .between(let until):
            return ("Short gap", "Back at it at \(time(until))")
        case .onBreak(let b, let ends):
            return ("\(b.name) — step away", "Back at \(time(ends))")
        case .inMeeting(let m):
            return (m.title, "Until \(time(m.end))")
        case .endOfDay(let r):
            var parts: [String] = []
            parts.append(r.meetingCount == 1 ? "1 meeting" : "\(r.meetingCount) meetings")
            if r.focusMinutes > 0 { parts.append("you got \(duration(minutes: r.focusMinutes)) of focus time!") }
            return ("That's a wrap for today", parts.joined(separator: " · "))
        case .dayOff:
            return ("Not a working day", "Enjoy it.")
        }
    }
}
