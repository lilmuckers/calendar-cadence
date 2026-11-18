import CadenceCore
import Foundation
import os

/// Sends a "Running late" message as you, to exactly the place you picked: a Teams meeting chat, a Google
/// Chat DM or group chat, a Slack channel or DM, or email. Never falls back to a different account on its own.
/// Only ever called from a click.
@MainActor
final class LateMessenger {
    /// Whether an option can be used right now, from asking the service where that's cheap.
    enum Check: Equatable {
        case checking
        case ready(String?)
        case unavailable(String)

        var isUsable: Bool { if case .ready = self { true } else { false } }
    }

    private let google: GoogleAuth
    private let microsoft: MicrosoftAuth
    private let slack: SlackAuth
    private let log = Logger(subsystem: "com.cadence.calendarmonitor", category: "late")
    /// Answers from `check`, by option id, so reopening the menu doesn't ask again.
    private var checks: [String: (Check, Date)] = [:]

    init(google: GoogleAuth, microsoft: MicrosoftAuth, slack: SlackAuth) {
        self.google = google
        self.microsoft = microsoft
        self.slack = slack
    }

    /// Every address you're signed in with, so "you" can be left out of recipients.
    var myEmails: Set<String> {
        Set((google.accounts.compactMap(\.email) + microsoft.accounts.compactMap(\.email)).map { $0.lowercased() })
    }

    /// All accounts, with what each is allowed to do. Ones without permission still appear, so the
    /// menu can say how to enable them.
    var accounts: [MessagingAccount] {
        let g = google.accounts.map { a in
            let on = a.messagingEnabled == true && !google.needsReconnect.contains(a.id)
            return MessagingAccount(id: a.id, kind: .google, email: a.email, label: a.label,
                                    canMail: on && a.canSendMail == true, canChat: on && a.canChat == true)
        }
        let m = microsoft.accounts.map { a in
            let on = a.messagingEnabled == true && !microsoft.needsReconnect.contains(a.id)
            return MessagingAccount(id: a.id, kind: .microsoft, email: a.email, label: a.label,
                                    canMail: on && a.canSendMail == true, canChat: on && a.canTeamsChat == true)
        }
        let s = slack.accounts.map { a in
            MessagingAccount(id: a.id, kind: .slack, email: nil, label: "\(a.label) Slack", canMail: false,
                             canChat: !slack.needsReconnect.contains(a.id), slackTeam: a.teamID)
        }
        return g + m + s
    }

    /// Whether any account can send anything at all.
    var isSetUp: Bool { accounts.contains { $0.canMail || $0.canChat } }

    func options(for meeting: Meeting, rules: [LateDomainRule], preferredAccountIDs: [String]) -> [LateOption] {
        RunningLate.options(for: meeting, accounts: accounts, rules: rules, preferredAccountIDs: preferredAccountIDs, myEmails: myEmails)
    }

    // MARK: Checking

    func cachedCheck(_ option: LateOption) -> Check? {
        guard let (check, at) = checks[option.id], Date().timeIntervalSince(at) < 300 else { return nil }
        return check
    }

    /// Asks the service whether this option will work (finds the Teams chat, looks the person up in Slack,
    /// looks for an existing Google Chat DM). Doesn't send anything.
    func check(_ option: LateOption) async -> Check {
        if let cached = cachedCheck(option) { return cached }
        let result: Check
        if let blocked = option.blocked {
            result = .unavailable(blocked)
        } else {
            do { result = try await probe(option) } catch { result = .unavailable(Self.short(error)) }
        }
        checks[option.id] = (result, Date())
        return result
    }

    private func probe(_ option: LateOption) async throws -> Check {
        switch option.target {
        case .teamsMeetingChat(let threadID, let joinURL):
            let token = try await msToken(option.accountID)
            if threadID == nil { _ = try await teamsThread(joinURL: joinURL, token: token) }
            return .ready(nil)
        case .googleDM(let email):
            let token = try await googleToken(option.accountID)
            do {
                _ = try await findDM(email: email, token: token)
                return .ready(nil)
            } catch SendError.http(404, _) {
                return .ready("starts a new chat")
            }
        case .googleGroup:
            _ = try await googleToken(option.accountID)
            return .ready("starts a group chat")
        case .slackChannel:
            _ = try await slackToken(option.accountID)
            return .ready(nil)
        case .slackDM(let email):
            let token = try await slackToken(option.accountID)
            _ = try await slackUser(email: email, token: token)
            return .ready(nil)
        case .email:
            return .ready(nil)
        }
    }

    // MARK: Sending

    func send(_ text: String, via option: LateOption, meeting: Meeting) async throws {
        if let blocked = option.blocked { throw SendError.unexpected(blocked) }
        do {
            try await deliver(text, via: option, meeting: meeting)
        } catch {
            checks[option.id] = (.unavailable(Self.short(error)), Date())
            log.info("Running-late via \(option.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func deliver(_ text: String, via option: LateOption, meeting: Meeting) async throws {
        switch option.target {
        case .teamsMeetingChat(let threadID, let joinURL):
            let token = try await msToken(option.accountID)
            let thread: String
            if let threadID { thread = threadID } else { thread = try await teamsThread(joinURL: joinURL, token: token) }
            try await request("POST", "https://graph.microsoft.com/v1.0/chats/\(escape(thread))/messages",
                              json: ["body": ["contentType": "text", "content": text]], token: token)

        case .googleDM(let email):
            let token = try await googleToken(option.accountID)
            let space: String
            do {
                space = try await findDM(email: email, token: token)
            } catch SendError.http(404, _) {
                space = try await setUpSpace(type: "DIRECT_MESSAGE", emails: [email], token: token)
            }
            try await request("POST", "https://chat.googleapis.com/v1/\(space)/messages", json: ["text": text], token: token)

        case .googleGroup(let emails):
            let token = try await googleToken(option.accountID)
            let space = try await setUpSpace(type: "GROUP_CHAT", emails: emails, token: token)
            try await request("POST", "https://chat.googleapis.com/v1/\(space)/messages", json: ["text": text], token: token)

        case .slackChannel(let channel):
            let token = try await slackToken(option.accountID)
            try await slackCall("chat.postMessage", json: ["channel": channel, "text": text], token: token)

        case .slackDM(let email):
            let token = try await slackToken(option.accountID)
            let user = try await slackUser(email: email, token: token)
            let open = try await slackCall("conversations.open", json: ["users": user], token: token)
            guard let channel = (open["channel"] as? [String: Any])?["id"] as? String else { throw SendError.unexpected("couldn't open a DM") }
            try await slackCall("chat.postMessage", json: ["channel": channel, "text": text], token: token)

        case .email(let to):
            let subject = "Running late: \(meeting.title)"
            if let account = google.accounts.first(where: { $0.id == option.accountID }) {
                let token = try await google.validAccessToken(for: account)
                let raw = Self.rfc822(from: account.email, to: to, subject: subject, body: text)
                try await request("POST", "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
                                  json: ["raw": raw.base64URL], token: token)
            } else {
                let token = try await msToken(option.accountID)
                try await request("POST", "https://graph.microsoft.com/v1.0/me/sendMail", json: [
                    "message": [
                        "subject": subject,
                        "body": ["contentType": "Text", "content": text],
                        "toRecipients": to.map { ["emailAddress": ["address": $0]] },
                    ],
                    "saveToSentItems": true,
                ], token: token)
            }
        }
    }

    // MARK: Service helpers

    private func googleToken(_ id: String) async throws -> String {
        guard let a = google.accounts.first(where: { $0.id == id }) else { throw SendError.noAccount }
        return try await google.validAccessToken(for: a)
    }

    private func msToken(_ id: String) async throws -> String {
        guard let a = microsoft.accounts.first(where: { $0.id == id }) else { throw SendError.noAccount }
        return try await microsoft.validAccessToken(for: a)
    }

    private func slackToken(_ id: String) async throws -> String {
        guard let a = slack.accounts.first(where: { $0.id == id }) else { throw SendError.noAccount }
        return try await slack.validToken(for: a)
    }

    /// The meeting chat's thread id for a Teams join link (works with an attendee's token, not just the organiser's).
    private func teamsThread(joinURL: URL, token: String) async throws -> String {
        var comps = URLComponents(string: "https://graph.microsoft.com/v1.0/me/onlineMeetings")!
        comps.queryItems = [URLQueryItem(name: "$filter", value: "JoinWebUrl eq '\(joinURL.absoluteString)'")]
        let json = try await request("GET", comps.url!.absoluteString, token: token)
        guard let first = (json["value"] as? [[String: Any]])?.first,
              let thread = (first["chatInfo"] as? [String: Any])?["threadId"] as? String else {
            throw SendError.unexpected("this account can't see the meeting's chat")
        }
        return thread
    }

    private func findDM(email: String, token: String) async throws -> String {
        var comps = URLComponents(string: "https://chat.googleapis.com/v1/spaces:findDirectMessage")!
        comps.queryItems = [URLQueryItem(name: "name", value: "users/\(email)")]
        let space = try await request("GET", comps.url!.absoluteString, token: token)
        guard let name = space["name"] as? String else { throw SendError.unexpected("no DM space") }
        return name
    }

    private func setUpSpace(type: String, emails: [String], token: String) async throws -> String {
        let space = try await request("POST", "https://chat.googleapis.com/v1/spaces:setup", json: [
            "space": ["spaceType": type],
            "memberships": emails.map { ["member": ["name": "users/\($0)", "type": "HUMAN"]] },
        ], token: token)
        guard let name = space["name"] as? String else { throw SendError.unexpected("couldn't start a chat") }
        return name
    }

    private func slackUser(email: String, token: String) async throws -> String {
        var comps = URLComponents(string: "https://slack.com/api/users.lookupByEmail")!
        comps.queryItems = [URLQueryItem(name: "email", value: email)]
        let json = try await request("GET", comps.url!.absoluteString, token: token)
        guard json["ok"] as? Bool == true, let id = (json["user"] as? [String: Any])?["id"] as? String else {
            let error = json["error"] as? String ?? "lookup failed"
            throw SendError.unexpected(error == "users_not_found" ? "they're not in this Slack workspace" : error)
        }
        return id
    }

    @discardableResult
    private func slackCall(_ method: String, json: [String: Any], token: String) async throws -> [String: Any] {
        let r = try await request("POST", "https://slack.com/api/\(method)", json: json, token: token)
        guard r["ok"] as? Bool == true else { throw SendError.unexpected("Slack: \(r["error"] as? String ?? "error")") }
        return r
    }

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:@"))) ?? s
    }

    enum SendError: LocalizedError {
        case noAccount, http(Int, String), unexpected(String)
        var errorDescription: String? {
            switch self {
            case .noAccount: "that account isn't signed in"
            case .http(let code, let body): "\(Self.reason(body)) (HTTP \(code))"
            case .unexpected(let why): why
            }
        }

        /// The error message from a JSON error body, kept short.
        static func reason(_ body: String) -> String {
            if let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] {
                if let e = error as? [String: Any], let m = e["message"] as? String { return m }
                if let s = error as? String { return s }
            }
            return String(body.prefix(120))
        }
    }

    static func short(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.count > 140 ? String(text.prefix(140)) + "…" : text
    }

    @discardableResult
    private func request(_ method: String, _ url: String, json: [String: Any]? = nil, token: String) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw SendError.unexpected("bad URL") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SendError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// A plain-text email in RFC 822 form, for Gmail's `raw`.
    static func rfc822(from: String?, to: [String], subject: String, body: String) -> Data {
        let encodedSubject = "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        var lines = [
            "To: \(to.joined(separator: ", "))",
            "Subject: \(encodedSubject)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
        ]
        if let from { lines.insert("From: \(from)", at: 0) }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }
}
