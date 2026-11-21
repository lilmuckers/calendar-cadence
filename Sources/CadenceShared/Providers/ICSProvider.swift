import CadenceCore
import Foundation

/// A subscribed iCalendar feed (https:// or webcal://), e.g. a secret Google/Outlook/iCloud ICS link.
struct ICSFeed: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var color: RGBAColor
    var enabled = true

    var fetchURL: URL? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("webcal://") { s = "https://" + s.dropFirst("webcal://".count) }
        return URL(string: s)
    }

    var calendarID: String { "ics:\(id.uuidString)" }

    static let palette: [RGBAColor] = [
        RGBAColor(red: 0.20, green: 0.60, blue: 0.95), RGBAColor(red: 0.95, green: 0.45, blue: 0.25),
        RGBAColor(red: 0.30, green: 0.75, blue: 0.45), RGBAColor(red: 0.65, green: 0.40, blue: 0.95),
        RGBAColor(red: 0.95, green: 0.30, blue: 0.55), RGBAColor(red: 0.95, green: 0.75, blue: 0.20),
    ]
}

@MainActor
final class ICSProvider: CalendarProvider {
    let feed: ICSFeed
    var onChange: (() -> Void)?
    private(set) var events: [ICSEvent] = []
    private(set) var lastError: String?
    private(set) var lastFetch: Date?

    init(feed: ICSFeed) { self.feed = feed }

    var name: String { feed.name }
    var isAuthorized: Bool { true }
    func requestAccess() async -> Bool { true }

    private var info: CalendarInfo {
        CalendarInfo(id: feed.calendarID, title: feed.name, sourceTitle: "Subscribed feeds", color: feed.color, kind: .ics)
    }

    func calendars() -> [CalendarInfo] { [info] }

    func meetings(from start: Date, to end: Date) -> [Meeting] {
        ICSParser.meetings(from: events, calendar: info, window: start..<end)
    }

    func refreshRemote() async {
        guard let url = feed.fetchURL else { lastError = "Invalid URL"; onChange?(); return }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("text/calendar", forHTTPHeaderField: "Accept")
            let (data, response) = try await HTTP.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            guard text.contains("BEGIN:VCALENDAR") else {
                throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "Not an iCalendar feed"])
            }
            // Shown windows start today at the earliest; keep a day of slack for time zones.
            let cutoff = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)
            events = ICSParser.relevant(ICSParser.parse(text), from: cutoff)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        lastFetch = Date()
        onChange?()
    }

    var status: String {
        if let lastError { return "Error: \(lastError)" }
        guard lastFetch != nil else { return "Not fetched yet" }
        return "\(events.count) events"
    }
}
