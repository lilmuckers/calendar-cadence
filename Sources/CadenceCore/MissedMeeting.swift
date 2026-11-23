import Foundation

/// How long a meeting with a join link that started without anyone joining keeps its countdown on
/// the iPhone's Live Activity, counting up in red, before it goes away.
public enum MissedMeetingLinger: Int, Codable, CaseIterable, Sendable {
    case immediately = 0
    case oneMinute = 1
    case twoMinutes = 2
    case fiveMinutes = 5
    case tenMinutes = 10
    /// Until the meeting ends.
    case indefinitely = -1

    public var label: String {
        switch self {
        case .immediately: "Immediately"
        case .oneMinute: "After 1 minute"
        case .twoMinutes: "After 2 minutes"
        case .fiveMinutes: "After 5 minutes"
        case .tenMinutes: "After 10 minutes"
        case .indefinitely: "When it ends"
        }
    }

    /// When the missed countdown for a meeting from `start` to `end` goes away. Never after the end.
    public func hideDate(start: Date, end: Date) -> Date {
        guard self != .indefinitely else { return end }
        return min(end, start.addingTimeInterval(TimeInterval(rawValue) * 60))
    }
}

/// What the Live Activity follows: the next meeting, or one in progress. A joined meeting drops out
/// (it's handled), and so does a missed one once its linger time is up.
public enum ActivityPlanner {
    public struct Focus: Equatable, Sendable {
        public var meeting: Meeting
        /// In progress and counting down to its end (a meeting without a join link, so nobody can be
        /// late for it in the "didn't press Join" sense).
        public var live: Bool
        /// Has a join link: once it starts without a join it counts as missed (red, counting up)
        /// until this date, then goes away.
        public var missedUntil: Date?
    }

    /// Tracked as missed or joined: only meetings you join with a link.
    public static func tracksJoin(_ meeting: Meeting) -> Bool { meeting.joinLink != nil }

    public static func focus(meetings: [Meeting], now: Date, isHidden: (Meeting) -> Bool,
                             hasJoined: (Meeting) -> Bool, linger: MissedMeetingLinger) -> Focus? {
        let gone: (Meeting) -> Bool = { m in
            if isHidden(m) { return true }
            guard tracksJoin(m) else { return false }
            if hasJoined(m) { return true }
            return m.start <= now && now >= linger.hideDate(start: m.start, end: m.end)
        }
        guard let f = PanelPlanner.focus(meetings: meetings, now: now, isHidden: gone, withinMinutes: 0, showDuringMeetings: true)
        else { return nil }
        let m = f.meeting
        guard tracksJoin(m) else { return Focus(meeting: m, live: f.live, missedUntil: nil) }
        return Focus(meeting: m, live: false, missedUntil: linger.hideDate(start: m.start, end: m.end))
    }
}
