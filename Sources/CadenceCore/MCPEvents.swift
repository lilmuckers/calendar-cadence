import Foundation

/// Something that happened, pushed to connected MCP clients.
public struct MCPEvent: Equatable, Sendable {
    public var type: String
    public var message: String
    public var data: JSONValue
    /// Resources whose content changed because of this event.
    public var uris: [String]
    /// Send as a log notification (false = only refresh subscribed resources).
    public var log: Bool
    public var level: String
    public var at: Date

    public init(type: String, message: String, data: JSONValue = .null, uris: [String] = [],
                log: Bool = true, level: String = "info", at: Date = Date()) {
        self.type = type
        self.message = message
        self.data = data
        self.uris = uris
        self.log = log
        self.level = level
        self.at = at
    }

    public var payload: JSONValue {
        ["type": .string(type), "message": .string(message), "at": .string(MeetingDTO.format(at)), "data": data]
    }
}

/// Timed meeting events (starting soon, started, ending soon, ended).
public enum MCPEventPlanner {
    public struct Due: Equatable, Sendable {
        public var key: String
        public var type: String
        public var meeting: Meeting
        public var fireAt: Date
    }

    /// Events whose moment has come and that haven't been sent, at most `staleness` late.
    public static func due(_ meetings: [Meeting], now: Date, sent: Set<String>,
                           leadMinutes: Int, wrapMinutes: Int, staleness: TimeInterval = 120) -> [Due] {
        var out: [Due] = []
        for m in meetings where !m.isAllDay && !m.isCanceled && m.participation != .declined {
            let moments: [(String, Date)] = [
                ("meeting.starting_soon", m.start.addingTimeInterval(-Double(leadMinutes) * 60)),
                ("meeting.started", m.start),
                ("meeting.ending_soon", m.end.addingTimeInterval(-Double(wrapMinutes) * 60)),
                ("meeting.ended", m.end),
            ]
            for (type, at) in moments {
                if type == "meeting.ending_soon", at <= m.start { continue }
                let key = "\(type):\(m.id)"
                if !sent.contains(key), at <= now, now.timeIntervalSince(at) <= staleness {
                    out.append(Due(key: key, type: type, meeting: m, fireAt: at))
                }
            }
        }
        return out.sorted { $0.fireAt < $1.fireAt }
    }

    public static func message(_ d: Due, now: Date) -> String {
        let m = d.meeting
        switch d.type {
        case "meeting.starting_soon":
            return "\(m.title) starts in \(CountdownFormatter.short(m.start.timeIntervalSince(now)))"
        case "meeting.started": return "\(m.title) has started"
        case "meeting.ending_soon":
            return "\(m.title) ends in \(CountdownFormatter.short(m.end.timeIntervalSince(now)))"
        default: return "\(m.title) has ended"
        }
    }
}

/// Spots meetings that moved or were cancelled between two snapshots.
public enum MeetingChangeDetector {
    public enum Change: Equatable, Sendable {
        case moved(from: Meeting, to: Meeting)
        case canceled(Meeting)
    }

    /// Only one-off upcoming meetings are compared (recurring ids shift between occurrences).
    /// EventKit ids embed the start time, so meetings are matched by series id.
    public static func changes(old: [Meeting], new: [Meeting], now: Date) -> [Change] {
        func index(_ ms: [Meeting]) -> [String: Meeting] {
            var out: [String: Meeting] = [:]
            var dupes: Set<String> = []
            for m in ms where !m.recurs && !m.isAllDay && m.end > now {
                if out[m.seriesID] != nil { dupes.insert(m.seriesID) }
                out[m.seriesID] = m
            }
            for d in dupes { out[d] = nil }
            return out
        }
        let before = index(old), after = index(new)
        var result: [Change] = []
        for (key, n) in after {
            guard let o = before[key] else { continue }
            if !o.isCanceled && n.isCanceled { result.append(.canceled(n)) }
            else if o.start != n.start || o.end != n.end { result.append(.moved(from: o, to: n)) }
        }
        return result.sorted { a, b in
            func start(_ c: Change) -> Date { if case .moved(_, let to) = c { return to.start }; if case .canceled(let m) = c { return m.start }; return now }
            return start(a) < start(b)
        }
    }
}

/// Free time between meetings within working hours.
public enum FreeTimeFinder {
    /// `workStart`/`workEnd` are minutes after midnight. Weekends are skipped.
    public static func slots(meetings: [Meeting], from: Date, to: Date, minDuration: TimeInterval,
                             workStart: Int, workEnd: Int, calendar: Calendar = .current) -> [DateInterval] {
        let busy = meetings
            .filter { !$0.isAllDay && !$0.isCanceled && $0.participation != .declined && $0.availability != .free }
            .map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
            .sorted { $0.start < $1.start }
        var result: [DateInterval] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day)! }
            if calendar.isDateInWeekend(day) { continue }
            var cursor = max(from, day.addingTimeInterval(Double(workStart) * 60))
            let dayEnd = min(to, day.addingTimeInterval(Double(workEnd) * 60))
            guard cursor < dayEnd else { continue }
            for b in busy where b.end > cursor && b.start < dayEnd {
                if b.start.timeIntervalSince(cursor) >= minDuration { result.append(DateInterval(start: cursor, end: b.start)) }
                cursor = max(cursor, b.end)
            }
            if dayEnd.timeIntervalSince(cursor) >= minDuration { result.append(DateInterval(start: cursor, end: dayEnd)) }
        }
        return result
    }

    /// Free time on each working day of `schedule`, in its hours (or `hours`, minutes after midnight,
    /// when given), keeping breaks clear when the schedule protects them.
    public static func slots(meetings: [Meeting], from: Date, to: Date, minDuration: TimeInterval,
                             schedule: WorkSchedule, hours: (Int, Int)? = nil, calendar: Calendar = .current) -> [DateInterval] {
        var busy = meetings
            .filter { !$0.isAllDay && !$0.isCanceled && $0.participation != .declined && $0.availability != .free && !$0.isBreak }
            .map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        if schedule.enabled && schedule.defences.protectInFreeTime {
            var day = calendar.startOfDay(for: from)
            while day < to {
                busy += schedule.breaks(on: day, calendar: calendar).map(\.1)
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }
        busy.sort { $0.start < $1.start }
        var result: [DateInterval] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day)! }
            guard var span = schedule.hours(on: day, calendar: calendar) else { continue }
            if let hours {
                span = DateInterval(start: WorkSchedule.at(hours.0, day, calendar), end: WorkSchedule.at(max(hours.0, hours.1), day, calendar))
            }
            var cursor = max(from, span.start)
            let dayEnd = min(to, span.end)
            guard cursor < dayEnd else { continue }
            for b in busy where b.end > cursor && b.start < dayEnd {
                if b.start.timeIntervalSince(cursor) >= minDuration { result.append(DateInterval(start: cursor, end: b.start)) }
                cursor = max(cursor, b.end)
            }
            if dayEnd.timeIntervalSince(cursor) >= minDuration { result.append(DateInterval(start: cursor, end: dayEnd)) }
        }
        return result
    }

    /// Parses "09:00-17:30" into minutes after midnight.
    public static func parseHours(_ s: String) -> (Int, Int)? {
        let parts = s.replacingOccurrences(of: " ", with: "").split(separator: "-")
        guard parts.count == 2 else { return nil }
        func minutes(_ p: Substring) -> Int? {
            let hm = p.split(separator: ":").compactMap { Int($0) }
            guard let h = hm.first, (0...24).contains(h) else { return nil }
            let m = hm.count > 1 ? hm[1] : 0
            return (0..<60).contains(m) ? h * 60 + m : nil
        }
        guard let a = minutes(parts[0]), let b = minutes(parts[1]), a < b else { return nil }
        return (a, b)
    }
}
