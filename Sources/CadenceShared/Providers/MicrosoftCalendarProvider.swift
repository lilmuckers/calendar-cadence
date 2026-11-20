import CadenceCore
import Foundation

/// Reads Outlook / Microsoft 365 calendars through Microsoft Graph, and replies to invites.
@MainActor
final class MicrosoftCalendarProvider: CalendarProvider {
    let name = "Microsoft 365"
    var onChange: (() -> Void)?
    let auth: MicrosoftAuth
    let accountID: String

    private(set) var lastError: String?
    private(set) var lastFetch: Date?
    private var cachedCalendars: [CalendarInfo] = []
    private var cachedMeetings: [Meeting] = []
    private var categoryColors: [String: RGBAColor] = [:]
    /// Meeting id → Graph event id (series master for recurring ones), for replies.
    private var refs: [String: String] = [:]
    private var defaultCalendar: (graphID: String, info: CalendarInfo)?

    private static let fields = "id,subject,start,end,isAllDay,isCancelled,isOrganizer,location,body,onlineMeeting,onlineMeetingUrl,responseStatus,showAs,organizer,attendees,categories,type,seriesMasterId"
    private static let inviteFields = "id,subject,start,end,isAllDay,isCancelled,isOrganizer,location,onlineMeeting,responseStatus,showAs,organizer,attendees,categories,type,seriesMasterId"

    init(accountID: String, auth: MicrosoftAuth) {
        self.accountID = accountID
        self.auth = auth
    }

    var account: MicrosoftAccount? { auth.accounts.first { $0.id == accountID } }
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
            if account.email == nil, let me = try? await getJSON("me?$select=mail,userPrincipalName", token: token) {
                if let mail = (me["mail"] as? String) ?? (me["userPrincipalName"] as? String) { auth.setEmail(mail, for: accountID) }
            }
            // Profile photo (many accounts have none: Graph answers 404).
            AvatarStore.shared.refresh(account.avatarKey) { [weak self] in
                guard let self else { return nil }
                guard let (data, response) = try? await HTTP.session.data(for: self.request("me/photo/$value", token: token)),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return data
            }
            // Category colours are optional (MailboxSettings.Read may be blocked by an admin).
            if let cats: GraphList<GraphCategory> = try? await get("me/outlook/masterCategories", token: token) {
                categoryColors = Dictionary(cats.value.compactMap { c in GraphMapper.categoryColor(c.color).map { (c.displayName, $0) } },
                                            uniquingKeysWith: { a, _ in a })
            }
            let cals: GraphList<GraphCalendar> = try await get("me/calendars?$select=id,name,color,hexColor,isDefaultCalendar&$top=100", token: token)
            let source = "Microsoft · \(account.label)"
            let pairs = cals.value.map { c in
                (c, CalendarInfo(id: "msft:\(accountID):\(c.id)", title: c.name ?? "Calendar", sourceTitle: source, color: GraphMapper.calendarColor(c), kind: .microsoft))
            }
            cachedCalendars = pairs.map(\.1)
            defaultCalendar = pairs.first { $0.0.isDefaultCalendar == true }.map { ($0.0.id, $0.1) }

            let cal = Calendar.current
            let from = cal.startOfDay(for: Date())
            let to = cal.date(byAdding: .day, value: 2, to: from)!
            var meetings: [Meeting] = []
            for (graph, info) in pairs {
                meetings += try await calendarView(graph.id, info: info, from: from, to: to, fields: Self.fields, token: token, maxPages: 10)
            }
            cachedMeetings = meetings
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        lastFetch = Date()
        onChange?()
    }

    private func calendarView(_ graphID: String, info: CalendarInfo, from: Date, to: Date, fields: String,
                              token: String, maxPages: Int) async throws -> [Meeting] {
        let iso = ISO8601DateFormatter()
        var url: String? = "me/calendars/\(escape(graphID))/calendarView?startDateTime=\(iso.string(from: from))&endDateTime=\(iso.string(from: to))&$top=250&$select=\(fields)"
        var out: [Meeting] = []
        var pages = 0
        while let next = url, pages < maxPages {
            let page: GraphList<GraphEvent> = try await get(next, token: token)
            for e in page.value {
                guard let m = GraphMapper.meeting(e, calendar: info, categoryColors: categoryColors) else { continue }
                // Replying to a series master answers every occurrence.
                refs[m.id] = e.seriesMasterId ?? e.id
                out.append(m)
            }
            url = page.nextLink
            pages += 1
        }
        return out
    }

    // MARK: Invites

    func fetchInvites(until: Date?) async -> [Meeting] {
        guard let account, let defaultCalendar else { return [] }
        do {
            let token = try await auth.validAccessToken(for: account)
            let from = Calendar.current.startOfDay(for: Date())
            let to = until ?? Calendar.current.date(byAdding: .year, value: 1, to: from)!
            return try await calendarView(defaultCalendar.graphID, info: defaultCalendar.info, from: from, to: to,
                                          fields: Self.inviteFields, token: token, maxPages: 12)
                .filter { $0.participation == .pending }
        } catch {
            return []
        }
    }

    func canRespond(_ meeting: Meeting) -> Bool { refs[meeting.id] != nil && account?.canWrite != false }

    func respond(_ meeting: Meeting, _ reply: RSVP) async throws {
        guard let account, let eventID = refs[meeting.id] else { throw ProviderError.unsupported }
        if account.canWrite == false { throw ProviderError.needsReconnect(account.label) }
        let token = try await auth.validAccessToken(for: account)
        let action = ["accept": "accept", "tentative": "tentativelyAccept", "decline": "decline"][reply.rawValue]!
        try await post("me/events/\(escape(eventID))/\(action)", body: ["sendResponse": true], token: token)
        // Microsoft has it; Cadence shows the reply straight away and re-reads in the background.
        Task { await refreshRemote() }
    }

    // MARK: HTTP

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s
    }

    private func request(_ pathOrURL: String, token: String) -> URLRequest {
        let url = pathOrURL.hasPrefix("https://") ? URL(string: pathOrURL)! : URL(string: "https://graph.microsoft.com/v1.0/" + pathOrURL)!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("outlook.timezone=\"\(TimeZone.current.identifier)\", outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")
        return req
    }

    private func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        let (data, response) = try await HTTP.session.data(for: request(path, token: token))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ProviderError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func getJSON(_ path: String, token: String) async throws -> [String: Any] {
        let (data, _) = try await HTTP.session.data(for: request(path, token: token))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func post(_ path: String, body: [String: Any], token: String) async throws {
        var req = request(path, token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await HTTP.session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403, let account { throw ProviderError.needsReconnect(account.label) }
        guard (200..<300).contains(code) else { throw ProviderError.http(code, String(data: data, encoding: .utf8) ?? "") }
    }

    var status: String {
        if account == nil { return "Not signed in" }
        if auth.needsReconnect.contains(accountID) { return "Needs reconnecting" }
        if let lastError { return "Error: \(lastError)" }
        guard lastFetch != nil else { return "Connecting…" }
        return "\(cachedCalendars.count) calendars · \(cachedMeetings.count) events in the next 2 days"
    }
}
