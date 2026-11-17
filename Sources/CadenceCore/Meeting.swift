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
}

/// The current user's response to an invite.
public enum Participation: String, Codable, Sendable {
    case accepted, declined, tentative, pending, unknown
}

/// How the event marks the user's time.
public enum Availability: String, Codable, Sendable {
    case busy, free, tentative, unavailable, unknown
}

/// A calendar the user can toggle on or off.
public struct CalendarInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var sourceTitle: String
    public var color: RGBAColor

    public init(id: String, title: String, sourceTitle: String, color: RGBAColor) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.color = color
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
    public var attendeeCount: Int
    public var participation: Participation
    public var availability: Availability
    public var joinLink: MeetingLink?

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
        attendeeCount: Int = 0,
        participation: Participation = .unknown,
        availability: Availability = .busy,
        joinLink: MeetingLink? = nil
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
        self.attendeeCount = attendeeCount
        self.participation = participation
        self.availability = availability
        self.joinLink = joinLink
    }

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
