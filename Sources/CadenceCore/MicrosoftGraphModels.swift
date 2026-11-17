import Foundation

/// Microsoft Graph (Outlook / Microsoft 365) calendar payloads — only the fields Cadence uses.
public struct GraphList<T: Decodable & Sendable>: Decodable, Sendable {
    public var value: [T]
    public var nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

public struct GraphCalendar: Decodable, Sendable {
    public var id: String
    public var name: String?
    public var color: String?
    public var hexColor: String?
    public var isDefaultCalendar: Bool?
}

public struct GraphCategory: Decodable, Sendable {
    public var displayName: String
    public var color: String?
}

public struct GraphEvent: Decodable, Sendable {
    public struct Time: Decodable, Sendable { public var dateTime: String }
    public struct Location: Decodable, Sendable { public var displayName: String? }
    public struct Body: Decodable, Sendable { public var content: String? }
    public struct Online: Decodable, Sendable { public var joinUrl: String? }
    public struct Response: Decodable, Sendable { public var response: String? }
    public struct Email: Decodable, Sendable { public var name: String?; public var address: String? }
    public struct Recipient: Decodable, Sendable { public var emailAddress: Email? }

    public var id: String
    public var subject: String?
    public var start: Time?
    public var end: Time?
    public var isAllDay: Bool?
    public var isCancelled: Bool?
    public var isOrganizer: Bool?
    public var location: Location?
    public var body: Body?
    public var onlineMeeting: Online?
    public var onlineMeetingUrl: String?
    public var responseStatus: Response?
    public var showAs: String?
    public var organizer: Recipient?
    public var attendees: [Recipient]?
    public var categories: [String]?
    public var type: String?
    public var seriesMasterId: String?
}

public enum GraphMapper {
    /// Outlook's category colour presets (preset0…preset24).
    static let presets = [
        "#e74c3c", "#f39c12", "#a0522d", "#f1c40f", "#2ecc71", "#1abc9c", "#808000", "#3498db", "#9b59b6",
        "#c0392b", "#7f8c8d", "#34495e", "#95a5a6", "#4d4d4d", "#000000", "#8b0000", "#d35400", "#5d4037",
        "#b7950b", "#1e8449", "#117a65", "#556b2f", "#1f3a93", "#5b2c6f", "#78281f",
    ]

    public static func categoryColor(_ preset: String?) -> RGBAColor? {
        guard let preset, preset.hasPrefix("preset"), let i = Int(preset.dropFirst(6)), presets.indices.contains(i) else { return nil }
        return GoogleMapper.color(hex: presets[i])
    }

    /// A calendar's colour: its hex colour when set, else the named colour.
    public static func calendarColor(_ c: GraphCalendar) -> RGBAColor {
        if let hex = c.hexColor, hex.count == 7 { return GoogleMapper.color(hex: hex) }
        let named: [String: String] = [
            "lightBlue": "#69afe5", "lightGreen": "#6fc172", "lightOrange": "#f7a35c", "lightGray": "#a8a8a8",
            "lightYellow": "#f1d25c", "lightTeal": "#4fc4c1", "lightPink": "#e57fb5", "lightBrown": "#b98a63",
            "lightRed": "#e8605c",
        ]
        return GoogleMapper.color(hex: named[c.color ?? ""] ?? "#4f8fe8")
    }

    /// Parses Graph's "2026-11-17T10:00:00.0000000" (zone given by the Prefer header).
    static func date(_ t: GraphEvent.Time?, in tz: TimeZone) -> Date? {
        guard let raw = t?.dateTime else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(raw.prefix(19)))
    }

    public static func meeting(_ e: GraphEvent, calendar: CalendarInfo, timeZone: TimeZone = .current,
                               categoryColors: [String: RGBAColor] = [:]) -> Meeting? {
        guard let start = date(e.start, in: timeZone), let end = date(e.end, in: timeZone) else { return nil }
        let participation: Participation
        switch e.responseStatus?.response {
        case "accepted", "organizer": participation = .accepted
        case "tentativelyAccepted": participation = .tentative
        case "declined": participation = .declined
        case "notResponded": participation = e.isOrganizer == true ? .accepted : .pending
        default: participation = e.isOrganizer == false ? .unknown : .accepted
        }
        let availability: Availability
        switch e.showAs {
        case "free", "workingElsewhere": availability = .free
        case "tentative": availability = .tentative
        case "oof": availability = .unavailable
        default: availability = .busy
        }
        let online = e.onlineMeeting?.joinUrl ?? e.onlineMeetingUrl
        var link = online.flatMap { MeetingLinkDetector.firstMeetingLink(in: $0) }
        if link == nil, let online, let url = URL(string: online) { link = MeetingLinkDetector.firstMeetingLink(in: url.absoluteString) ?? MeetingLink(service: .other, url: url) }
        let notes = e.body?.content
        let location = e.location?.displayName.flatMap { $0.isEmpty ? nil : $0 }
        if link == nil { link = MeetingLinkDetector.detect(url: nil, location: location, notes: notes) }
        let recurs = e.type == "occurrence" || e.type == "exception" || e.type == "seriesMaster"
        let masterID = e.type == "seriesMaster" ? e.id : e.seriesMasterId

        return Meeting(
            id: "msft:\(calendar.id):\(e.id)",
            title: e.subject?.isEmpty == false ? e.subject! : "Untitled",
            start: start,
            end: end,
            isAllDay: e.isAllDay ?? false,
            isCanceled: e.isCancelled ?? false,
            calendar: calendar,
            location: location,
            notes: notes,
            organizer: e.organizer?.emailAddress?.name ?? e.organizer?.emailAddress?.address,
            attendeeCount: e.attendees?.count ?? 0,
            participation: participation,
            availability: availability,
            joinLink: link,
            eventColor: e.categories?.lazy.compactMap { categoryColors[$0] }.first,
            recurs: recurs,
            series: masterID.map { "msft:\(calendar.id):\($0)" }
        )
    }
}
