import Foundation

/// The "Leave now" reminder times shown in Settings. Stored as minutes before you need to leave
/// (`Preferences.leaveOffsets`, e.g. `[10, 0]`); 0 is the "time to leave" reminder itself.
public enum LeaveOffsets {
    /// Times offered when adding a reminder.
    public static let presets = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]
    /// Offsets accepted (the same range the old free-text field allowed).
    public static let range = 0...240

    /// "When it's time to leave", "5 minutes before leaving", "1 hour before leaving", "1 hr 30 min before leaving".
    public static func label(_ minutes: Int) -> String {
        if minutes <= 0 { return "When it's time to leave" }
        let h = minutes / 60, m = minutes % 60
        let amount: String
        switch (h, m) {
        case (0, _): amount = m == 1 ? "1 minute" : "\(m) minutes"
        case (_, 0): amount = h == 1 ? "1 hour" : "\(h) hours"
        default: amount = "\(h) hr \(m) min"
        }
        return "\(amount) before leaving"
    }

    /// De-duplicated, in range, earliest reminder first (largest offset first): the order they fire.
    public static func normalized(_ offsets: [Int]) -> [Int] {
        Set(offsets.filter { range.contains($0) }).sorted(by: >)
    }

    /// Presets not already chosen.
    public static func available(excluding chosen: [Int]) -> [Int] {
        presets.filter { !chosen.contains($0) }
    }
}

/// A one-off reminder (heads-up, leave-now) tied to a meeting.
public struct Reminder: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case headsUp(minutes: Int)
        /// `offset` minutes before you need to leave; 0 = time to leave.
        case leave(offset: Int, travel: TimeInterval)
        /// `minutes` before a live meeting ends; `next` is a meeting starting right after it.
        case wrapUp(minutes: Int, next: Meeting?)
        /// Morning digest of the day ahead.
        case summary(day: Date, meetings: [Meeting])
        /// A break starts now (`meeting` is the break's stand-in).
        case breakStart
        /// The live `meeting` is about to run into `breakMeeting`.
        case breakOverrun(breakMeeting: Meeting)
        /// Working hours just ended: how the day went.
        case dayWrap(DayRecap)
    }

    public var key: String
    public var meeting: Meeting
    public var kind: Kind
    public var fireAt: Date

    public init(key: String, meeting: Meeting, kind: Kind, fireAt: Date) {
        self.key = key
        self.meeting = meeting
        self.kind = kind
        self.fireAt = fireAt
    }

    /// After this the reminder is pointless: a meeting's start, or its end for wrap-ups.
    public var deadline: Date {
        switch kind {
        case .wrapUp: meeting.end
        case .summary(let day, _): Calendar.current.date(byAdding: .hour, value: 4, to: fireAt) ?? day
        case .breakStart: meeting.end
        case .breakOverrun(let b): b.start
        case .dayWrap: fireAt.addingTimeInterval(3600)
        default: meeting.start
        }
    }

    public var isSummary: Bool {
        if case .summary = kind { return true }
        return false
    }

    /// About a break rather than a meeting: nothing to join.
    public var isBreak: Bool {
        switch kind {
        case .breakStart, .breakOverrun: true
        default: false
        }
    }

    /// Only worth sending while you're actually on the call: a wrap-up for an online meeting (one with a
    /// join link). If the mic isn't in use you've already left, so there's nothing to wrap up. In-person
    /// meetings can't be detected, so their wrap-ups always go out.
    public var needsActiveCall: Bool {
        if case .wrapUp = kind { return meeting.joinLink != nil }
        return false
    }

    /// A note about the day rather than a meeting: nothing to join, no need to interrupt.
    public var isAboutTheDay: Bool {
        switch kind {
        case .summary, .breakStart, .breakOverrun, .dayWrap: true
        default: false
        }
    }

    /// What a "Join" action on this reminder should open.
    public var joinTarget: Meeting {
        if case .wrapUp(_, let next?) = kind { return next }
        return meeting
    }
}

public enum ReminderPlanner {
    public static func headsUps(for meetings: [Meeting], minutes: Int) -> [Reminder] {
        meetings.filter { !$0.isAllDay }.map {
            Reminder(key: "heads:\(minutes):\($0.id)", meeting: $0, kind: .headsUp(minutes: minutes),
                     fireAt: $0.start.addingTimeInterval(-Double(minutes) * 60))
        }
    }

    /// Leave reminders for a meeting given an estimated travel time.
    public static func leaves(for meeting: Meeting, travel: TimeInterval, offsets: [Int]) -> [Reminder] {
        let leaveAt = meeting.start.addingTimeInterval(-travel)
        return Set(offsets).sorted(by: >).map { offset in
            Reminder(key: "leave:\(offset):\(meeting.id)", meeting: meeting,
                     kind: .leave(offset: offset, travel: travel),
                     fireAt: leaveAt.addingTimeInterval(-Double(offset) * 60))
        }
    }

    /// Gap that still counts as "straight after" for the wrap-up nudge.
    public static let backToBackGap: TimeInterval = 5 * 60

    /// A wrap-up nudge `minutes` before each live meeting ends, naming the meeting that starts straight
    /// after it, if any. With `onlyBackToBack`, meetings with nothing after them are skipped.
    public static func wrapUps(live: [Meeting], all: [Meeting], minutes: Int, onlyBackToBack: Bool) -> [Reminder] {
        live.filter { !$0.isAllDay && $0.duration > Double(minutes) * 60 }.compactMap { m in
            let next = all
                .filter { n in
                    !n.isAllDay && n.id != m.id && n.participation != .declined && !n.isCanceled
                        && n.start >= m.end.addingTimeInterval(-60) && n.start.timeIntervalSince(m.end) <= backToBackGap
                        && !MeetingDeduplicator.isSameMeeting(n, m)
                }
                .min { $0.start < $1.start }
            if onlyBackToBack && next == nil { return nil }
            return Reminder(key: "wrap:\(minutes):\(m.id)", meeting: m, kind: .wrapUp(minutes: minutes, next: next),
                            fireAt: m.end.addingTimeInterval(-Double(minutes) * 60))
        }
    }

    /// How long before a break the overrun warning goes out.
    public static let overrunLead: TimeInterval = 5 * 60

    /// A nudge as each break starts, and (for meetings live across a break's start) a warning
    /// `overrunLead` before. `breaks` are the stand-ins from `WorkSchedule.breakMeetings`, already
    /// without the ones you gave up; `live` the meetings you're in.
    public static func breakNudges(breaks: [Meeting], meetings: [Meeting], nudge: Bool, overrun: Bool) -> [Reminder] {
        var out: [Reminder] = []
        for b in breaks {
            if nudge {
                out.append(Reminder(key: "break:\(b.id)", meeting: b, kind: .breakStart, fireAt: b.start))
            }
            if overrun {
                for m in meetings where !m.isAllDay && !m.isCanceled && m.participation != .declined && !m.isBreak
                    && m.start < b.start.addingTimeInterval(-overrunLead) && m.end > b.start {
                    out.append(Reminder(key: "overrun:\(b.id):\(m.id)", meeting: m, kind: .breakOverrun(breakMeeting: b),
                                        fireAt: b.start.addingTimeInterval(-overrunLead)))
                }
            }
        }
        return out
    }

    /// Reminders whose time has come and that haven't been sent. A reminder only fires before the
    /// meeting starts, and at most `staleness` late (e.g. the Mac was asleep), so nothing stale pops up.
    public static func due(_ reminders: [Reminder], now: Date, sent: Set<String>, staleness: TimeInterval = 120) -> [Reminder] {
        reminders.filter { r in
            !sent.contains(r.key) && r.fireAt <= now && now < r.deadline
                && (r.isSummary || now.timeIntervalSince(r.fireAt) <= staleness)
        }
    }

    public static func message(for r: Reminder) -> (title: String, body: String) {
        switch r.kind {
        case .headsUp(let minutes):
            return ("\(r.meeting.title) in \(minutes) min", "\(r.meeting.calendar.title) · \(r.meeting.joinLink?.service.displayName ?? r.meeting.physicalLocation ?? "starts soon")")
        case .leave(let offset, let travel):
            let trip = "~\(CountdownFormatter.short(travel)) travel to \(r.meeting.physicalLocation ?? "the venue")"
            return offset == 0
                ? ("Time to leave for \(r.meeting.title)", trip)
                : ("Leave in \(offset) min for \(r.meeting.title)", trip)
        case .wrapUp(let minutes, let next):
            guard let next else {
                return ("\(r.meeting.title) ends in \(minutes) min", "Time to start wrapping up.")
            }
            let toNext = max(1, Int((next.start.timeIntervalSince(r.fireAt) / 60).rounded()))
            let via = next.joinLink?.service.displayName ?? next.physicalLocation
            return ("Wrap up: \(next.title) in \(toNext) min",
                    "\(r.meeting.title) ends at \(timeString(r.meeting.end))" + (via.map { " · next on \($0)" } ?? ""))
        case .summary(_, let meetings):
            let timed = meetings.filter { !$0.isAllDay }
            guard let first = timed.first else {
                return ("Good morning — no meetings today", "Enjoy the deep work.")
            }
            let count = timed.count == 1 ? "1 meeting" : "\(timed.count) meetings"
            let pending = meetings.filter { $0.participation == .pending }.count
            var body = "First up: \(first.title) at \(timeString(first.start))"
            if let last = timed.last, timed.count > 1 { body += " · done by \(timeString(last.end))" }
            if pending > 0 { body += " · \(pending) to RSVP" }
            return ("Good morning — \(count) today", body)
        case .breakStart:
            return ("Time for \(r.meeting.title)", "Step away — back at \(timeString(r.meeting.end)).")
        case .breakOverrun(let b):
            return ("\(b.title) starts in 5 min", "\(r.meeting.title) runs until \(timeString(r.meeting.end)) — time to wrap up?")
        case .dayWrap(let recap):
            let text = DayPlanner.message(for: .endOfDay(recap), now: r.fireAt)
            return (text.title, text.detail)
        }
    }

    static func timeString(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    /// "That's a wrap for today" as working hours end, with the day's meetings and focus time.
    /// nil on a day off or with the schedule off. `meetings` are the ones that count (not muted by a clash).
    public static func dayWrap(meetings: [Meeting], schedule: WorkSchedule, now: Date,
                               calendar: Calendar = .current) -> Reminder? {
        guard schedule.enabled, let hours = schedule.hours(on: now, calendar: calendar) else { return nil }
        let recap = DayPlanner.recap(meetings: meetings, schedule: schedule, day: now, calendar: calendar)
        let anchor = Meeting(id: "daywrap", title: "Today", start: hours.end, end: hours.end,
                             calendar: CalendarInfo(id: "daywrap", title: "", sourceTitle: "", color: .gray))
        let key = "daywrap:\(Int(calendar.startOfDay(for: now).timeIntervalSince1970))"
        return Reminder(key: key, meeting: anchor, kind: .dayWrap(recap), fireAt: hours.end)
    }

    /// The once-a-day summary, due from `hour:minute` for 4 hours so a late wake still gets it.
    public static func morningSummary(meetings: [Meeting], now: Date, hour: Int, minute: Int) -> Reminder? {
        let cal = Calendar.current
        guard let at = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        let day = cal.startOfDay(for: now)
        let today = meetings.filter { cal.isDate($0.start, inSameDayAs: now) && !$0.isCanceled && $0.participation != .declined }
        let anchor = Meeting(id: "summary", title: "Today", start: at, end: at,
                             calendar: CalendarInfo(id: "summary", title: "", sourceTitle: "", color: .gray))
        let key = "summary:\(Int(day.timeIntervalSince1970))"
        return Reminder(key: key, meeting: anchor, kind: .summary(day: day, meetings: today), fireAt: at)
    }
}

/// A group of overlapping meetings (copies already merged) that can't all be attended.
public struct Clash: Equatable, Sendable {
    public var meetings: [Meeting]
    /// Stable identity for remembering the user's choice.
    public var key: String { meetings.map(\.id).sorted().joined(separator: "|") }
}

public enum ClashDetector {
    /// How much two meetings may overlap before it counts as a clash, by default. Times from
    /// different sources can disagree by seconds (an end stored as 13:00:00.4, or a start at
    /// 12:59:59 from another feed), so back-to-back meetings need a little slack.
    public static let defaultOverlapTolerance: TimeInterval = 30

    /// The tolerances offered in Settings, from 1 second to 5 minutes.
    public static let overlapToleranceOptions: [TimeInterval] = [1, 5, 10, 15, 30, 60, 120, 180, 300]

    /// "1 second", "30 seconds", "1 minute", "5 minutes"…
    public static func toleranceLabel(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 60, s % 60 == 0 { return s == 60 ? "1 minute" : "\(s / 60) minutes" }
        return s == 1 ? "1 second" : "\(s) seconds"
    }

    /// Whether two time ranges overlap by more than `tolerance`. Back-to-back meetings, and ones
    /// that overlap by the tolerance or less, don't.
    public static func overlaps(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date,
                                tolerance: TimeInterval = defaultOverlapTolerance) -> Bool {
        min(aEnd, bEnd).timeIntervalSince(max(aStart, bStart)) > tolerance
    }

    /// Clusters timed meetings that overlap by more than `tolerance` (back-to-back doesn't count).
    public static func clashes(in meetings: [Meeting], after now: Date,
                               tolerance: TimeInterval = defaultOverlapTolerance) -> [Clash] {
        let timed = meetings
            .filter { !$0.isAllDay && !$0.isCanceled && $0.participation != .declined && $0.availability != .free && $0.end > now }
            .sorted { $0.start < $1.start }
        var result: [Clash] = []
        var cluster: [Meeting] = []
        var clusterEnd = Date.distantPast
        for m in timed {
            // Sorted by start, so m's overlap with the cluster so far runs from m.start to the
            // earlier of the two ends; it clashes only past the tolerance.
            if !cluster.isEmpty && min(m.end, clusterEnd).timeIntervalSince(m.start) > tolerance {
                if !cluster.contains(where: { MeetingDeduplicator.isSameMeeting($0, m) }) { cluster.append(m) }
                clusterEnd = max(clusterEnd, m.end)
            } else {
                if cluster.count > 1 { result.append(Clash(meetings: cluster)) }
                cluster = [m]
                clusterEnd = m.end
            }
        }
        if cluster.count > 1 { result.append(Clash(meetings: cluster)) }
        return result
    }

    /// Meetings whose alerts should be suppressed given the user's choices (clash key → chosen meeting id, or "all").
    public static func suppressed(clashes: [Clash], choices: [String: String]) -> Set<String> {
        var out: Set<String> = []
        for clash in clashes {
            guard let choice = choices[clash.key], choice != "all" else { continue }
            for m in clash.meetings where m.id != choice { out.insert(m.id) }
        }
        return out
    }
}
