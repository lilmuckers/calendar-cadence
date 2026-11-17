import Foundation

/// A one-off reminder (heads-up, leave-now) tied to a meeting.
public struct Reminder: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case headsUp(minutes: Int)
        /// `offset` minutes before you need to leave; 0 = time to leave.
        case leave(offset: Int, travel: TimeInterval)
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

    /// Reminders whose time has come and that haven't been sent. A reminder only fires before the
    /// meeting starts, and at most `staleness` late (e.g. the Mac was asleep), so nothing stale pops up.
    public static func due(_ reminders: [Reminder], now: Date, sent: Set<String>, staleness: TimeInterval = 120) -> [Reminder] {
        reminders.filter { r in
            !sent.contains(r.key) && r.fireAt <= now && now < r.meeting.start
                && now.timeIntervalSince(r.fireAt) <= staleness
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
        }
    }
}

/// A group of overlapping meetings (copies already merged) that can't all be attended.
public struct Clash: Equatable, Sendable {
    public var meetings: [Meeting]
    /// Stable identity for remembering the user's choice.
    public var key: String { meetings.map(\.id).sorted().joined(separator: "|") }
}

public enum ClashDetector {
    /// Clusters timed meetings whose times overlap (back-to-back doesn't count).
    public static func clashes(in meetings: [Meeting], after now: Date) -> [Clash] {
        let timed = meetings
            .filter { !$0.isAllDay && !$0.isCanceled && $0.participation != .declined && $0.availability != .free && $0.end > now }
            .sorted { $0.start < $1.start }
        var result: [Clash] = []
        var cluster: [Meeting] = []
        var clusterEnd = Date.distantPast
        for m in timed {
            if !cluster.isEmpty && m.start < clusterEnd {
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
