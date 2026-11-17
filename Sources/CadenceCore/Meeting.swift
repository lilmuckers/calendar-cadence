import Foundation

/// A colour stored as plain components so the core module stays UI-framework free.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let gray = RGBAColor(red: 0.55, green: 0.55, blue: 0.58)

    /// "#RGB", "#RRGGBB" (with or without "#"), or a common CSS colour name, as used by the
    /// iCalendar COLOR property (RFC 7986).
    public init?(css raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = Self.cssNames[s] { self.init(css: named); return }
        var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    private static let cssNames: [String: String] = [
        "red": "ff0000", "crimson": "dc143c", "tomato": "ff6347", "coral": "ff7f50", "orange": "ffa500",
        "darkorange": "ff8c00", "gold": "ffd700", "yellow": "ffff00", "khaki": "f0e68c", "green": "008000",
        "lime": "00ff00", "limegreen": "32cd32", "seagreen": "2e8b57", "olive": "808000", "teal": "008080",
        "turquoise": "40e0d0", "cyan": "00ffff", "aqua": "00ffff", "skyblue": "87ceeb", "lightblue": "add8e6",
        "dodgerblue": "1e90ff", "royalblue": "4169e1", "blue": "0000ff", "navy": "000080", "indigo": "4b0082",
        "purple": "800080", "violet": "ee82ee", "orchid": "da70d6", "magenta": "ff00ff", "fuchsia": "ff00ff",
        "pink": "ffc0cb", "hotpink": "ff69b4", "brown": "a52a2a", "chocolate": "d2691e", "sienna": "a0522d",
        "gray": "808080", "grey": "808080", "silver": "c0c0c0", "black": "000000", "white": "ffffff",
    ]
}

/// The current user's response to an invite.
public enum Participation: String, Codable, Sendable {
    case accepted, declined, tentative, pending, unknown
}

/// How the event marks the user's time.
public enum Availability: String, Codable, Sendable {
    case busy, free, tentative, unavailable, unknown
}

/// Where a calendar comes from, for showing a source badge.
public enum CalendarKind: String, Codable, Sendable {
    /// Signed in directly in Cadence.
    case google, microsoft, ics
    /// Accounts in macOS Calendar (System Settings → Internet Accounts).
    case iCloud, googleViaMac, exchange, calDAV, subscribed, birthdays, local
    case other

    public var label: String {
        switch self {
        case .google: "Google Calendar (signed in to Cadence)"
        case .microsoft: "Microsoft 365 / Outlook (signed in to Cadence)"
        case .ics: "Subscribed ICS feed (added in Cadence)"
        case .iCloud: "iCloud, via macOS Calendar"
        case .googleViaMac: "Google, via macOS Calendar"
        case .exchange: "Exchange / Outlook, via macOS Calendar"
        case .calDAV: "CalDAV, via macOS Calendar"
        case .subscribed: "Subscribed calendar, via macOS Calendar"
        case .birthdays: "Contacts birthdays"
        case .local: "On this Mac"
        case .other: "Calendar"
        }
    }
}

/// A calendar the user can toggle on or off.
public struct CalendarInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var sourceTitle: String
    public var color: RGBAColor
    public var kind: CalendarKind

    public init(id: String, title: String, sourceTitle: String, color: RGBAColor, kind: CalendarKind = .other) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.color = color
        self.kind = kind
    }
}

/// A provider-agnostic calendar event.
public struct Meeting: Identifiable, Hashable, Sendable {
    /// Unique per occurrence (recurring events share an EventKit identifier, so the start time is folded in).
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCanceled: Bool
    public var calendar: CalendarInfo
    public var location: String?
    public var notes: String?
    public var url: URL?
    public var organizer: String?
    /// The organizer's email address, when the source gives one (used for browser-profile rules).
    public var organizerEmail: String?
    public var attendeeCount: Int
    public var participation: Participation
    public var availability: Availability
    public var joinLink: MeetingLink?
    /// A colour set on this event itself (Google's per-event colour, ICS COLOR), overriding the calendar's.
    public var eventColor: RGBAColor?
    /// Part of a recurring series.
    public var recurs: Bool
    /// Explicit series identity, for sources whose ids don't encode it (Microsoft Graph).
    public var series: String?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isCanceled: Bool = false,
        calendar: CalendarInfo,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        organizer: String? = nil,
        organizerEmail: String? = nil,
        attendeeCount: Int = 0,
        participation: Participation = .unknown,
        availability: Availability = .busy,
        joinLink: MeetingLink? = nil,
        eventColor: RGBAColor? = nil,
        recurs: Bool = false,
        series: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCanceled = isCanceled
        self.calendar = calendar
        self.location = location
        self.notes = notes
        self.url = url
        self.organizer = organizer
        self.organizerEmail = organizerEmail
        self.attendeeCount = attendeeCount
        self.participation = participation
        self.availability = availability
        self.joinLink = joinLink
        self.eventColor = eventColor
        self.recurs = recurs
        self.series = series
    }

    /// The event's own colour if it has one, else its calendar's.
    public var displayColor: RGBAColor { eventColor ?? calendar.color }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func isInProgress(at now: Date) -> Bool { start <= now && now < end }

    /// A location worth showing on a map: not empty, not a URL, not just a meeting-service name.
    public var physicalLocation: String? {
        guard let location, LocationClassifier.isPhysical(location) else { return nil }
        return location.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum LocationClassifier {
    private static let virtualMarkers = [
        "microsoft teams", "teams meeting", "zoom", "google meet", "meet.google", "webex",
        "gotomeeting", "whereby", "jitsi", "chime", "slack", "skype", "discord", "facetime",
        "online", "virtual", "remote", "tbd", "tba", "n/a", "phone", "call",
    ]

    public static func isPhysical(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return false }
        let lower = text.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return false }
        // Location fields often hold several entries separated by ";" — physical if any part looks like a place.
        let parts = lower.split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.contains { part in
            if part.contains("://") || part.hasPrefix("www.") || part.hasPrefix("+") { return false }
            if ["phone", "dial", "tel:", "passcode", "meeting id"].contains(where: { part.contains($0) }) { return false }
            let mentionsVirtual = virtualMarkers.contains { part.contains($0) }
            // "Microsoft Teams Meeting" is virtual; "Zoom Room 4B, 12 Main St" still has an address.
            return !mentionsVirtual || part.contains(where: \.isNumber)
        }
    }
}
