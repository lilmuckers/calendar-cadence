import Foundation

/// Tracks which meetings have triggered the full-screen alert. Pure state machine so it can be tested with a fake clock.
public struct AlertPlanner: Sendable {
    /// How late (after start) a missed alert may still fire, e.g. when the Mac wakes from sleep.
    public var lateGrace: TimeInterval = 60
    /// How long after start a snoozed alert may still fire.
    public var snoozeGrace: TimeInterval = 10 * 60

    public private(set) var fired: Set<String> = []
    public private(set) var snoozedUntil: [String: Date] = [:]

    public init() {}

    /// The meeting whose alert is due now, if any. Call once per tick; then call `markFired`.
    public func due(in meetings: [Meeting], now: Date, leadTime: TimeInterval) -> Meeting? {
        let candidates = meetings
            .filter { !$0.isAllDay && !$0.isCanceled }
            .sorted { $0.start < $1.start }
        for meeting in candidates {
            if let until = snoozedUntil[meeting.id] {
                if now >= until && now < meeting.start.addingTimeInterval(snoozeGrace) { return meeting }
                continue
            }
            if fired.contains(meeting.id) { continue }
            let window = meeting.start.addingTimeInterval(-leadTime)..<meeting.start.addingTimeInterval(lateGrace)
            if window.contains(now) { return meeting }
        }
        return nil
    }

    public mutating func markFired(_ meeting: Meeting) {
        fired.insert(meeting.id)
        snoozedUntil[meeting.id] = nil
    }

    public mutating func snooze(_ meeting: Meeting, until date: Date) {
        fired.insert(meeting.id)
        snoozedUntil[meeting.id] = date
    }

    /// Forget meetings that are long over so the sets do not grow forever.
    public mutating func prune(keeping meetings: [Meeting]) {
        let ids = Set(meetings.map(\.id))
        fired = fired.intersection(ids)
        snoozedUntil = snoozedUntil.filter { ids.contains($0.key) }
    }
}

/// Human-friendly countdown strings.
public enum CountdownFormatter {
    /// "1:05:09", "12:34", "0:30"
    public static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "3h 20m", "12m", "45s"
    public static func short(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        if total < 60 { return "\(total)s" }
        let minutes = (total + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
