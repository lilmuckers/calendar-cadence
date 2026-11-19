import Foundation

/// A reply to an invitation.
public enum RSVP: String, Codable, CaseIterable, Sendable {
    case accept, tentative, decline

    public var label: String {
        switch self {
        case .accept: "Accept"
        case .tentative: "Maybe"
        case .decline: "Decline"
        }
    }

    public var participation: Participation {
        switch self {
        case .accept: .accepted
        case .tentative: .tentative
        case .decline: .declined
        }
    }
}

/// How far ahead to look for invitations that still need a reply.
public enum InviteHorizon: String, Codable, CaseIterable, Sendable {
    case today, twoDays, week, all

    public var label: String {
        switch self {
        case .today: "Today"
        case .twoDays: "Next 2 days"
        case .week: "1 week"
        case .all: "All time"
        }
    }

    /// End of the window (exclusive); nil means no limit.
    public func end(from now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return calendar.date(byAdding: .day, value: 1, to: today)
        case .twoDays: return calendar.date(byAdding: .day, value: 2, to: today)
        case .week: return calendar.date(byAdding: .day, value: 7, to: today)
        case .all: return nil
        }
    }
}

/// A colour the user can give an event.
public struct EventColorChoice: Identifiable, Hashable, Sendable {
    /// Google's colorId for the colour, which is also the key for local overrides.
    /// Custom label colours (no colorId) use "label:<label id>".
    public var id: String
    public var name: String
    public var color: RGBAColor
    /// The Google colour label this choice sets (`eventLabelId`), when the calendar has labels.
    public var labelID: String?

    public init(id: String, name: String, color: RGBAColor, labelID: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.labelID = labelID
    }

    /// Google Calendar's eleven event colours, in the order its colour menu lists them.
    public static let palette: [EventColorChoice] = [
        ("11", "Tomato"), ("4", "Flamingo"), ("6", "Tangerine"), ("5", "Banana"), ("2", "Sage"), ("10", "Basil"),
        ("7", "Peacock"), ("9", "Blueberry"), ("1", "Lavender"), ("3", "Grape"), ("8", "Graphite"),
    ].map { EventColorChoice(id: $0.0, name: $0.1, color: GoogleMapper.eventColor(id: $0.0)!) }

    public static func choice(id: String) -> EventColorChoice? { palette.first { $0.id == id } }

    /// The palette as one calendar labels it: a label on one of the standard colours renames that
    /// swatch; a label with a colour of its own is added after them.
    public static func palette(labels: [GoogleEventLabel]) -> [EventColorChoice] {
        var out = palette
        for label in labels {
            let hex = GoogleMapper.normalisedHex(label.backgroundColor)
            let name = label.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let hex, let i = out.firstIndex(where: { $0.labelID == nil && GoogleMapper.eventColors[$0.id] == hex }) {
                out[i].labelID = label.id
                if let name { out[i].name = name }
            } else if hex != nil {
                out.append(EventColorChoice(id: "label:\(label.id)", name: name ?? unnamedCustom,
                                            color: GoogleMapper.color(hex: hex), labelID: label.id))
            }
        }
        return out
    }

    /// True when the calendar gave this colour a name of its own (a renamed standard colour or a
    /// named custom colour), rather than Google's stock name or "Custom colour".
    public var isNamedLabel: Bool {
        labelID != nil && name != (Self.choice(id: id)?.name ?? Self.unnamedCustom)
    }

    static let unnamedCustom = "Custom colour"

    /// Just the colours the calendar named, plus `keeping` (the event's current colour) so it stays
    /// visible. Falls back to all of `choices` when the calendar named none.
    public static func namedOnly(_ choices: [EventColorChoice], keeping current: String? = nil) -> [EventColorChoice] {
        let named = choices.filter { $0.isNamedLabel || $0.id == current }
        return named.contains(where: \.isNamedLabel) ? named : choices
    }

    /// "Sage" for an unlabelled standard colour; "Focus time (Sage)" when the calendar renamed it.
    public var detail: String {
        guard let base = Self.choice(id: id)?.name, base != name else { return name }
        return "\(name) (\(base))"
    }
}

public enum InvitePlanner {
    /// Invites still awaiting a reply that haven't finished and start before the horizon,
    /// one per recurring series, soonest first.
    public static func pending(_ invites: [Meeting], now: Date, horizon: InviteHorizon) -> [Meeting] {
        let end = horizon.end(from: now)
        var seen: Set<String> = []
        return invites
            .filter { m in
                m.participation == .pending && !m.isCanceled
                    && (m.recurs || m.end > now)
                    && (end.map { m.start < $0 } ?? true)
            }
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.seriesID).inserted }
    }

    /// Collapses the same invite seen through two sources, preferring one we can reply to.
    public static func merge(_ invites: [Meeting], canRespond: (Meeting) -> Bool) -> [Meeting] {
        var kept: [Meeting] = []
        for m in invites.sorted(by: { canRespond($0) && !canRespond($1) }) {
            let dup = kept.contains { k in
                MeetingDeduplicator.isSameMeeting(k, m)
                    || (k.recurs && m.recurs && MeetingDeduplicator.normalizedTitle(k.title) == MeetingDeduplicator.normalizedTitle(m.title)
                        && k.organizer == m.organizer)
            }
            if !dup { kept.append(m) }
        }
        return kept.sorted { $0.start < $1.start }
    }

    /// Invites not seen before. With no history yet (first launch), nothing counts as new.
    public static func newInvites(_ invites: [Meeting], known: Set<String>?) -> [Meeting] {
        guard let known else { return [] }
        return invites.filter { !known.contains($0.seriesID) }
    }
}
