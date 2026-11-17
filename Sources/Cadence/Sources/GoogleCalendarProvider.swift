import CadenceCore
import Foundation

/// Reads Google Calendar directly through the API, which gives Meet/conference links and
/// RSVP status even when the account isn't added to macOS Calendar.
@MainActor
final class GoogleCalendarProvider: CalendarProvider {
    let name = "Google Calendar"
    var onChange: (() -> Void)?
    let auth: GoogleAuth
    let accountID: String

    private(set) var lastError: String?
    private(set) var lastFetch: Date?
    private var cachedCalendars: [CalendarInfo] = []
    private var cachedMeetings: [Meeting] = []

    init(accountID: String, auth: GoogleAuth) {
        self.accountID = accountID
        self.auth = auth
    }

    var account: GoogleAccount? { auth.accounts.first { $0.id == accountID } }
    var accountEmail: String? { account?.email }

    var isAuthorized: Bool { account != nil }
    func requestAccess() async -> Bool { isAuthorized }

    func calendars() -> [CalendarInfo] { cachedCalendars }

    func meetings(from start: Date, to end: Date) -> [Meeting] {
        cachedMeetings.filter { $0.end > start && $0.start < end }
    }

    func refreshRemote() async {
        guard let account else {
            cachedCalendars = []
            cachedMeetings = []
            onChange?()
            return
        }
        do {
            let token = try await auth.validAccessToken(for: account)
            let list: GoogleCalendarList = try await get("users/me/calendarList", query: ["minAccessRole": "reader"], token: token)
            let entries = (list.items ?? []).filter { $0.selected != false }
            if let primary = entries.first(where: { $0.primary == true })?.id { auth.setEmail(primary, for: accountID) }
            let source = "Google · \(accountEmail ?? "account")"
            // Calendar IDs are scoped per account: two accounts can both see the same shared calendar.
            cachedCalendars = entries.map {
                CalendarInfo(id: "gcal:\(accountID):\($0.id)", title: $0.title, sourceTitle: source, color: GoogleMapper.color(hex: $0.backgroundColor))
            }

            let cal = Calendar.current
            let from = cal.startOfDay(for: Date())
            let to = cal.date(byAdding: .day, value: 2, to: from)!
            let iso = ISO8601DateFormatter()
            var meetings: [Meeting] = []
            for (entry, info) in zip(entries, cachedCalendars) {
                let path = "calendars/\(entry.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/@#"))) ?? entry.id)/events"
                var pageToken: String?
                repeat {
                    var query = [
                        "timeMin": iso.string(from: from), "timeMax": iso.string(from: to),
                        "singleEvents": "true", "orderBy": "startTime", "maxResults": "250",
                        "conferenceDataVersion": "1",
                    ]
                    if let pageToken { query["pageToken"] = pageToken }
                    let page: GoogleEventList = try await get(path, query: query, token: token)
                    meetings += (page.items ?? []).compactMap { GoogleMapper.meeting($0, calendar: info) }
                    pageToken = page.nextPageToken
                } while pageToken != nil
            }
            cachedMeetings = meetings
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        lastFetch = Date()
        onChange?()
    }

    private func get<T: Decodable>(_ path: String, query: [String: String], token: String) async throws -> T {
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Google API HTTP \(code)"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    var status: String {
        if account == nil { return "Not signed in" }
        if auth.needsReconnect.contains(accountID) { return "Needs reconnecting" }
        if let lastError { return "Error: \(lastError)" }
        guard lastFetch != nil else { return "Connecting…" }
        return "\(cachedCalendars.count) calendars · \(cachedMeetings.count) events in the next 2 days"
    }
}
