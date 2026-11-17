import Foundation

/// The same meeting often arrives several times: once per calendar it was copied to, or once from
/// macOS Calendar and again from a direct Google/ICS source. These helpers collapse such copies.
public enum MeetingDeduplicator {
    static func normalizedTitle(_ s: String) -> String {
        var t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["fwd:", "fw:", "copy:", "updated invitation:", "invitation:"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Same time slot and either the same title or the same join link.
    public static func isSameMeeting(_ a: Meeting, _ b: Meeting) -> Bool {
        guard a.start == b.start, a.end == b.end, a.isAllDay == b.isAllDay else { return false }
        if normalizedTitle(a.title) == normalizedTitle(b.title) { return true }
        if let la = a.joinLink?.url, let lb = b.joinLink?.url, la == lb { return true }
        return false
    }

    /// Keeps one copy of each meeting, preferring the most informative one.
    public static func dedupe(_ meetings: [Meeting]) -> [Meeting] {
        var kept: [Meeting] = []
        for m in meetings {
            if let i = kept.firstIndex(where: { isSameMeeting($0, m) }) {
                if score(m) > score(kept[i]) { kept[i] = merged(primary: m, other: kept[i]) }
                else { kept[i] = merged(primary: kept[i], other: m) }
            } else {
                kept.append(m)
            }
        }
        return kept
    }

    private static func score(_ m: Meeting) -> Int {
        (m.joinLink != nil ? 4 : 0) + (m.participation != .unknown ? 2 : 0) + (m.location != nil ? 1 : 0)
    }

    private static func merged(primary: Meeting, other: Meeting) -> Meeting {
        var m = primary
        if m.joinLink == nil { m.joinLink = other.joinLink }
        if m.location == nil { m.location = other.location }
        if m.notes == nil { m.notes = other.notes }
        if m.eventColor == nil { m.eventColor = other.eventColor }
        if m.participation == .unknown { m.participation = other.participation }
        m.attendeeCount = max(m.attendeeCount, other.attendeeCount)
        return m
    }
}
