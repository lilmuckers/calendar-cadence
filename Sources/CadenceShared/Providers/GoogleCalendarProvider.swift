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
    /// Meeting id → where it lives in Google, for replies and colour changes.
    private var refs: [String: (calendarID: String, eventID: String)] = [:]
    private var primary: (entry: GoogleCalendarListEntry, info: CalendarInfo)?
    /// Google calendar id → the colour labels the user set up for it in Google Calendar.
    private var labels: [String: [GoogleEventLabel]] = [:]
    /// Set if Google ever refuses `eventLabelVersion` on a read, so we stop sending it.
    private var labelReadsRejected = false

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
            if let current = self.account {
                // Ask for a larger photo than the default 96px thumbnail.
                let url = current.pictureURL.map { $0.replacingOccurrences(of: "=s96-c", with: "=s128-c") }
                AvatarStore.shared.refresh(current.avatarKey, from: url.flatMap(URL.init(string:)))
            }
            let source = "Google · \(accountEmail ?? "account")"
            // Calendar IDs are scoped per account: two accounts can both see the same shared calendar.
            cachedCalendars = entries.map {
                CalendarInfo(id: "gcal:\(accountID):\($0.id)", title: $0.title, sourceTitle: source, color: GoogleMapper.color(hex: $0.backgroundColor), kind: .google)
            }
            primary = zip(entries, cachedCalendars).first { $0.0.primary == true }.map { ($0.0, $0.1) }

            await refreshLabels(entries, token: token)

            let cal = Calendar.current
            let from = cal.startOfDay(for: Date())
            let to = cal.date(byAdding: .day, value: 2, to: from)!
            let iso = ISO8601DateFormatter()
            var meetings: [Meeting] = []
            for (entry, info) in zip(entries, cachedCalendars) {
                let path = eventsPath(entry.id)
                var pageToken: String?
                repeat {
                    var query = [
                        "timeMin": iso.string(from: from), "timeMax": iso.string(from: to),
                        "singleEvents": "true", "orderBy": "startTime", "maxResults": "250",
                        "conferenceDataVersion": "1",
                    ]
                    if let pageToken { query["pageToken"] = pageToken }
                    let page = try await events(path, query: query, calendarID: entry.id, token: token)
                    meetings += map(page.items ?? [], calendarID: entry.id, info: info)
                    pageToken = page.nextPageToken
                } while pageToken != nil
            }
            cachedMeetings = meetings
            // Keep refs for invites fetched outside the 2-day window too; drop ones for gone calendars.
            let calendarIDs = Set(entries.map(\.id))
            refs = refs.filter { calendarIDs.contains($0.value.calendarID) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        lastFetch = Date()
        onChange?()
    }

    /// Reads each calendar's colour labels. Failures keep what we had: labels are a nicety.
    private func refreshLabels(_ entries: [GoogleCalendarListEntry], token: String) async {
        var fresh: [String: [GoogleEventLabel]] = [:]
        for entry in entries {
            do {
                let resource: GoogleCalendarResource = try await get("calendars/\(escape(entry.id))", query: [:], token: token)
                if !resource.labels.isEmpty { fresh[entry.id] = resource.labels }
            } catch {
                // A 403 here usually means the token lacks calendar.calendars.readonly: Reconnect the account.
                NSLog("Cadence: couldn't read colour labels for Google calendar \(entry.id): \(error)")
                if let old = labels[entry.id] { fresh[entry.id] = old }
            }
        }
        labels = fresh
    }

    /// An events page; asks for colour labels on calendars that have them.
    private func events(_ path: String, query: [String: String], calendarID: String, token: String) async throws -> GoogleEventList {
        guard labels[calendarID] != nil, !labelReadsRejected else { return try await get(path, query: query, token: token) }
        var labelled = query
        labelled["eventLabelVersion"] = "1"
        do {
            return try await get(path, query: labelled, token: token)
        } catch where error.localizedDescription.hasSuffix("HTTP 400") {
            NSLog("Cadence: Google rejected eventLabelVersion on \(calendarID), reading events without labels: \(error)")
            labelReadsRejected = true
            return try await get(path, query: query, token: token)
        }
    }

    private func labelColors(_ calendarID: String) -> [String: RGBAColor] {
        Dictionary((labels[calendarID] ?? []).map { ($0.id, GoogleMapper.color(hex: $0.backgroundColor)) }) { a, _ in a }
    }

    private func map(_ events: [GoogleEvent], calendarID: String, info: CalendarInfo) -> [Meeting] {
        let colors = labelColors(calendarID)
        return events.compactMap { e in
            guard let m = GoogleMapper.meeting(e, calendar: info, labels: colors) else { return nil }
            refs[m.id] = (calendarID, e.id)
            return m
        }
    }

    // MARK: Invites

    /// Unanswered invites on the primary calendar. Recurring series come back once (not expanded),
    /// so replying answers the whole series.
    func fetchInvites(until: Date?) async -> [Meeting] {
        guard let account, let primary else { return [] }
        do {
            let token = try await auth.validAccessToken(for: account)
            let iso = ISO8601DateFormatter()
            var query = [
                "timeMin": iso.string(from: Calendar.current.startOfDay(for: Date())),
                "singleEvents": "false", "maxResults": "250", "conferenceDataVersion": "1",
            ]
            if let until { query["timeMax"] = iso.string(from: until) }
            var invites: [Meeting] = []
            var pageToken: String?
            var pages = 0
            repeat {
                if let pageToken { query["pageToken"] = pageToken }
                let page = try await events(eventsPath(primary.entry.id), query: query, calendarID: primary.entry.id, token: token)
                let pending = (page.items ?? []).filter { e in
                    e.status != "cancelled" && e.attendees?.contains { $0.isSelf == true && $0.responseStatus == "needsAction" } == true
                }
                invites += map(pending, calendarID: primary.entry.id, info: primary.info)
                pageToken = page.nextPageToken
                pages += 1
            } while pageToken != nil && pages < 10
            return await withNextOccurrence(invites, calendarID: primary.entry.id, info: primary.info, token: token)
        } catch {
            return []
        }
    }

    /// A series comes back with its first occurrence's time, which is often long past. Swap in the
    /// next upcoming occurrence so the invite says when it actually happens next (replying still answers the series).
    private func withNextOccurrence(_ invites: [Meeting], calendarID: String, info: CalendarInfo, token: String) async -> [Meeting] {
        let now = Date()
        let colors = labelColors(calendarID)
        var out: [Meeting] = []
        for var m in invites {
            if m.recurs, m.end <= now, let ref = refs[m.id],
               let list: GoogleEventList = try? await get(
                   "\(eventsPath(calendarID))/\(escape(ref.eventID))/instances",
                   query: ["timeMin": ISO8601DateFormatter().string(from: now), "maxResults": "5"], token: token),
               let next = (list.items ?? [])
                   .filter({ $0.status != "cancelled" })
                   .compactMap({ GoogleMapper.meeting($0, calendar: info, labels: colors) })
                   .first(where: { $0.end > now }) {
                m.start = next.start
                m.end = next.end
            }
            out.append(m)
        }
        return out
    }

    func canRespond(_ meeting: Meeting) -> Bool {
        refs[meeting.id] != nil && account?.canWrite != false
    }

    func canSetColor(_ meeting: Meeting) -> Bool { canRespond(meeting) }

    func colorChoices(for meeting: Meeting) -> [EventColorChoice]? {
        guard let ref = refs[meeting.id], let labels = labels[ref.calendarID] else { return nil }
        return EventColorChoice.palette(labels: labels)
    }

    func respond(_ meeting: Meeting, _ reply: RSVP) async throws {
        let (token, ref) = try await writable(meeting)
        // PATCH replaces the whole attendee list, so fetch it and change only our own entry.
        let path = "\(eventsPath(ref.calendarID))/\(escape(ref.eventID))"
        let current = try await send("GET", path, token: token)
        guard var attendees = current["attendees"] as? [[String: Any]],
              let me = attendees.firstIndex(where: { $0["self"] as? Bool == true }) else { throw ProviderError.unsupported }
        attendees[me]["responseStatus"] = ["accept": "accepted", "tentative": "tentative", "decline": "declined"][reply.rawValue]
        _ = try await send("PATCH", path, query: ["sendUpdates": "all"], body: ["attendees": attendees], token: token)
        // Google has it; show it now and pick up the rest of the change in the background.
        updateCached(matching: ref.eventID, series: false) { $0.participation = reply.participation }
        Task { await refreshRemote() }
    }

    func setColor(_ meeting: Meeting, _ choice: EventColorChoice?) async throws {
        let (token, ref) = try await writable(meeting)
        // On a recurring event, colour the whole series.
        let eventID = meeting.recurs ? (ref.eventID.split(separator: "_").first.map(String.init) ?? ref.eventID) : ref.eventID
        let path = "\(eventsPath(ref.calendarID))/\(escape(eventID))"
        if let label = choice?.labelID {
            _ = try await send("PATCH", path, query: ["eventLabelVersion": "1"], body: ["eventLabelId": label], token: token)
        } else if choice == nil, labels[ref.calendarID] != nil {
            // Clear both systems so neither a label nor a legacy colour lingers.
            _ = try await send("PATCH", path, query: ["eventLabelVersion": "1"], body: ["eventLabelId": ""], token: token)
            _ = try await send("PATCH", path, body: ["colorId": NSNull()], token: token)
        } else {
            _ = try await send("PATCH", path, body: ["colorId": choice?.id ?? NSNull()], token: token)
        }
        updateCached(matching: eventID, series: meeting.recurs) { $0.eventColor = choice?.color }
        Task { await refreshRemote() }
    }

    /// Applies a confirmed change to cached events so it shows without waiting for a full re-fetch.
    private func updateCached(matching eventID: String, series: Bool, _ change: (inout Meeting) -> Void) {
        let hits = Set(refs.filter { $0.value.eventID == eventID || (series && $0.value.eventID.hasPrefix(eventID + "_")) }.keys)
        guard !hits.isEmpty else { return }
        cachedMeetings = cachedMeetings.map { m in
            guard hits.contains(m.id) else { return m }
            var m = m
            change(&m)
            return m
        }
        onChange?()
    }

    private func writable(_ meeting: Meeting) async throws -> (String, (calendarID: String, eventID: String)) {
        guard let account, let ref = refs[meeting.id] else { throw ProviderError.unsupported }
        if account.canWrite == false { throw ProviderError.needsReconnect(account.label) }
        return (try await auth.validAccessToken(for: account), ref)
    }

    private func eventsPath(_ calendarID: String) -> String { "calendars/\(escape(calendarID))/events" }

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/@#"))) ?? s
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil, token: String) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403, String(data: data, encoding: .utf8)?.contains("insufficient") == true, let account {
            auth.setCanWrite(false, for: account.id)
            throw ProviderError.needsReconnect(account.label)
        }
        guard (200..<300).contains(code) else { throw ProviderError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func get<T: Decodable>(_ path: String, query: [String: String], token: String) async throws -> T {
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Google's reason (e.g. insufficient scopes) rides along for logging; the description stays short.
            let reason = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Google API HTTP \(code)", "GoogleResponse": reason])
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
