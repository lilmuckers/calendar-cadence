import Foundation

/// How the floating countdown panel looks, smallest to largest.
public enum PanelStyle: String, Codable, CaseIterable, Comparable, Sendable {
    case mini, compact, standard

    public var label: String {
        switch self {
        case .mini: "Mini"
        case .compact: "Compact"
        case .standard: "Standard"
        }
    }

    public static func < (a: PanelStyle, b: PanelStyle) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    var larger: PanelStyle {
        let all = Self.allCases
        return all[min(all.count - 1, all.firstIndex(of: self)! + 1)]
    }
}

/// What the panel is showing.
public struct PanelFocus: Equatable, Sendable {
    public var meeting: Meeting
    /// True while the meeting is in progress (counting down to its end).
    public var live: Bool

    public var target: Date { live ? meeting.end : meeting.start }
}

public extension Meeting {
    /// Identifies every occurrence of a recurring event, for "hide all occurrences".
    /// EventKit and ICS ids are "<series>@<start>"; Google instance ids are "<series>_<start>".
    var seriesID: String {
        if let at = id.lastIndex(of: "@"), id[id.index(after: at)...].allSatisfy(\.isNumber) {
            return String(id[..<at])
        }
        if id.hasPrefix("gcal:"), let colon = id.lastIndex(of: ":") {
            let eventID = id[id.index(after: colon)...]
            if let underscore = eventID.lastIndex(of: "_") { return String(id[..<underscore]) }
        }
        return id
    }
}

public enum PanelPlanner {
    /// Thresholds for "grow as the meeting gets closer": one size up inside the first, full size inside the second.
    public static let growSteps: (first: TimeInterval, second: TimeInterval) = (15 * 60, 5 * 60)

    /// Picks what to show. Prefers the next meeting; shows a live one when the next is more than
    /// 10 minutes off. `withinMinutes` > 0 hides upcoming meetings further away than that.
    public static func focus(
        meetings: [Meeting],
        now: Date,
        isHidden: (Meeting) -> Bool,
        withinMinutes: Int,
        showDuringMeetings: Bool
    ) -> PanelFocus? {
        let cal = Calendar.current
        let timed = meetings.filter { !$0.isAllDay && !isHidden($0) }
        let next = timed.first { $0.start > now && cal.isDate($0.start, inSameDayAs: now) }
        let live = showDuringMeetings ? timed.last { $0.isInProgress(at: now) } : nil

        let nextInRange = next.flatMap { m -> Meeting? in
            guard withinMinutes > 0 else { return m }
            return m.start.timeIntervalSince(now) <= Double(withinMinutes) * 60 ? m : nil
        }

        if let live {
            if let nextInRange, nextInRange.start.timeIntervalSince(now) <= 600 { return PanelFocus(meeting: nextInRange, live: false) }
            return PanelFocus(meeting: live, live: true)
        }
        return nextInRange.map { PanelFocus(meeting: $0, live: false) }
    }

    /// The style to draw right now: the chosen one, or larger as the meeting approaches when `grow` is on.
    public static func style(base: PanelStyle, grow: Bool, focus: PanelFocus?, now: Date) -> PanelStyle {
        guard grow, let focus, !focus.live else { return base }
        let remaining = focus.meeting.start.timeIntervalSince(now)
        if remaining <= growSteps.second { return .standard }
        if remaining <= growSteps.first { return max(base, base.larger) }
        return base
    }
}
