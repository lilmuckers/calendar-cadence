import Foundation

/// Google Calendar API v3 payloads (only the fields Cadence uses).
public struct GoogleCalendarList: Decodable, Sendable {
    public var items: [GoogleCalendarListEntry]?
    public var nextPageToken: String?
}

public struct GoogleCalendarListEntry: Decodable, Sendable {
    public var id: String
    public var summary: String?
    public var summaryOverride: String?
    public var backgroundColor: String?
    public var primary: Bool?
    public var selected: Bool?
    public var accessRole: String?

    public var title: String { summaryOverride ?? summary ?? id }
}

/// The Google Calendar scopes Cadence signs in with. Kept here so a test guards the set.
public enum GoogleScopes {
    /// Reads (and, on a click, replies to or colours) events on every calendar.
    public static let events = "https://www.googleapis.com/auth/calendar.events"
    /// Lists the calendars so the user can choose which to show.
    public static let calendarList = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    /// Reads each calendar's own properties (`GET calendars/{id}`), which is where its colour label names live.
    /// calendarlist.readonly doesn't cover that call: without this scope Google answers 403 and the colour
    /// pickers fall back to Google's plain names.
    public static let calendars = "https://www.googleapis.com/auth/calendar.calendars.readonly"
    /// The narrowest set that works. calendar.readonly is broader (settings, sharing, free/busy) and Google's
    /// verification rejects it here.
    public static let calendar = [calendarList, calendars, events].joined(separator: " ")
}

/// A calendar's own colour labels (Calendars resource `labelProperties`): the names the user gave
/// event colours in Google Calendar, plus any custom colours.
public struct GoogleEventLabel: Decodable, Hashable, Sendable {
    public var id: String
    public var backgroundColor: String?
    public var name: String?

    public init(id: String, backgroundColor: String?, name: String?) {
        self.id = id
        self.backgroundColor = backgroundColor
        self.name = name
    }
}

public struct GoogleCalendarResource: Decodable, Sendable {
    public struct LabelProperties: Decodable, Sendable {
        public var eventLabels: [GoogleEventLabel]?
    }
    public var labelProperties: LabelProperties?
    public var labels: [GoogleEventLabel] { labelProperties?.eventLabels ?? [] }
}

public struct GoogleEventList: Decodable, Sendable {
    public var items: [GoogleEvent]?
    public var nextPageToken: String?
}

public struct GoogleEvent: Decodable, Sendable {
    public struct Time: Decodable, Sendable {
        public var dateTime: String?
        public var date: String?
    }

    public struct Person: Decodable, Sendable {
        public var email: String?
        public var displayName: String?
        public var isSelf: Bool?
        public var responseStatus: String?
        public var resource: Bool?

        enum CodingKeys: String, CodingKey {
            case email, displayName, responseStatus, resource
            case isSelf = "self"
        }
    }

    public struct Conference: Decodable, Sendable {
        public struct EntryPoint: Decodable, Sendable {
            public var entryPointType: String?
            public var uri: String?
        }
        public var entryPoints: [EntryPoint]?
    }

    public var id: String
    public var status: String?
    public var summary: String?
    public var description: String?
    public var location: String?
    public var hangoutLink: String?
    public var transparency: String?
    public var start: Time?
    public var end: Time?
    public var attendees: [Person]?
    public var organizer: Person?
    public var conferenceData: Conference?
    public var eventType: String?
    public var colorId: String?
    public var eventLabelId: String?
    public var recurringEventId: String?
    public var recurrence: [String]?
}

public enum GoogleMapper {
    public static func color(hex: String?) -> RGBAColor {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#"), s.count == 7 else { return .gray }
        s.removeFirst()
        guard let v = UInt32(s, radix: 16) else { return .gray }
        return RGBAColor(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Google's fixed event palette (colorId 1–11), as Google Calendar's web UI draws it.
    /// The API's /colors endpoint returns an older, paler set for the same ids.
    public static let eventColors: [String: String] = [
        "1": "#7986cb",  // Lavender
        "2": "#33b679",  // Sage
        "3": "#8e24aa",  // Grape
        "4": "#e67c73",  // Flamingo
        "5": "#f6bf26",  // Banana
        "6": "#f4511e",  // Tangerine
        "7": "#039be5",  // Peacock
        "8": "#616161",  // Graphite
        "9": "#3f51b5",  // Blueberry
        "10": "#0b8043", // Basil
        "11": "#d50000", // Tomato
    ]

    public static func eventColor(id: String?) -> RGBAColor? {
        id.flatMap { eventColors[$0] }.map { color(hex: $0) }
    }

    static func parse(_ t: GoogleEvent.Time?) -> (date: Date, allDay: Bool)? {
        guard let t else { return nil }
        if let dt = t.dateTime {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: dt) { return (d, false) }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: dt).map { ($0, false) }
        }
        if let day = t.date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: day).map { ($0, true) }
        }
        return nil
    }

    /// Normalised "#rrggbb" for comparing label colours with the fixed palette.
    static func normalisedHex(_ hex: String?) -> String? {
        guard let s = hex?.trimmingCharacters(in: .whitespaces).lowercased(), s.hasPrefix("#"), s.count == 7 else { return nil }
        return s
    }

    /// `labels`: the calendar's colour labels (label id → colour), so events tagged with a label get its colour.
    public static func meeting(_ e: GoogleEvent, calendar: CalendarInfo, labels: [String: RGBAColor] = [:]) -> Meeting? {
        // Working-location and out-of-office entries aren't meetings.
        if let type = e.eventType, type == "workingLocation" || type == "outOfOffice" || type == "focusTime" { return nil }
        guard let start = parse(e.start), let end = parse(e.end) else { return nil }

        let me = e.attendees?.first { $0.isSelf == true }
        let participation: Participation
        switch me?.responseStatus {
        case "accepted": participation = .accepted
        case "declined": participation = .declined
        case "tentative": participation = .tentative
        case "needsAction": participation = .pending
        default: participation = me == nil ? .accepted : .unknown
        }

        let video = e.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri ?? e.hangoutLink
        var link = video.flatMap { MeetingLinkDetector.firstMeetingLink(in: $0) }
        if link == nil, let video, let url = URL(string: video) { link = MeetingLink(service: .other, url: url) }
        if link == nil { link = MeetingLinkDetector.detect(url: nil, location: e.location, notes: e.description) }

        return Meeting(
            id: "gcal:\(calendar.id):\(e.id)",
            title: e.summary?.isEmpty == false ? e.summary! : "Untitled",
            start: start.date,
            end: end.date,
            isAllDay: start.allDay,
            isCanceled: e.status == "cancelled",
            calendar: calendar,
            location: e.location,
            notes: e.description,
            url: nil,
            organizer: e.organizer?.displayName ?? e.organizer?.email,
            organizerEmail: e.organizer?.email,
            attendeeCount: e.attendees?.count ?? 0,
            attendees: (e.attendees ?? []).map { Attendee(name: $0.displayName, email: $0.email, isSelf: $0.isSelf == true, isResource: $0.resource == true) },
            participation: participation,
            availability: e.transparency == "transparent" ? .free : (participation == .tentative ? .tentative : .busy),
            joinLink: link,
            eventColor: e.eventLabelId.flatMap { $0.isEmpty ? nil : labels[$0] } ?? eventColor(id: e.colorId),
            recurs: e.recurringEventId != nil || e.recurrence?.isEmpty == false
        )
    }
}
