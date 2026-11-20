import AppKit
import CryptoKit
import Foundation
import Observation

/// A Slack workspace you've signed in to. The user token (and refresh token) live in the Keychain.
struct SlackAccount: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var teamID: String
    var teamName: String
    var userID: String
    var clientID: String
    /// When the user token expires, if token rotation is on (nil = it doesn't).
    var tokenExpiry: Date?

    var tokenKey: String { "slack.token.\(id)" }
    var refreshKey: String { "slack.refreshToken.\(id)" }
    var label: String { teamName }
}

/// "Sign in with Slack" for a desktop app: OAuth v2 with PKCE and an HTTPS relay page that hands the browser back to a localhost listener; no client secret.
/// Asks only for user scopes (`chat:write`, `users:read`, `users:read.email`, `im:write`), so messages are posted as you.
@MainActor
@Observable
final class SlackAuth {
    enum AuthError: LocalizedError {
        case missingClient, denied(String), badResponse(String), notSignedIn

        var errorDescription: String? {
            switch self {
            case .missingClient: "Enter your Slack app's client ID first."
            case .denied(let why): "Slack sign-in was cancelled: \(why)"
            case .badResponse(let why): "Slack sign-in failed: \(why)"
            case .notSignedIn: "Not signed in to Slack."
            }
        }
    }

    /// Post as you; find someone by email and open a DM with them.
    static let userScope = "chat:write,users:read,users:read.email,im:write"
    /// Cadence listens here on this Mac for the end of the sign-in.
    static let port: UInt16 = 53_682
    /// Slack only distributes apps whose redirect URLs are HTTPS, so Slack sends the browser to this static
    /// page on the Cadence site, which forwards it straight to http://localhost:53682/slack. PKCE means the
    /// code is useless to anyone without the verifier Cadence keeps. Register exactly this URL in the Slack app.
    static let redirect = "https://cadence.patrick-mckinley.com/slack"
    private static let accountsKey = "Cadence.slack.accounts"
    private static let customClientKey = "Cadence.slack.clientID"

    private(set) var accounts: [SlackAccount] = []
    private(set) var needsReconnect: Set<String> = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let saved = try? JSONDecoder().decode([SlackAccount].self, from: data) {
            accounts = saved
        }
    }

    static let bundledClientID: String? = {
        let id = Bundle.main.infoDictionary?["CadenceSlackClientID"] as? String
        return id?.isEmpty == false ? id : nil
    }()

    var customClientID: String? {
        let id = UserDefaults.standard.string(forKey: Self.customClientKey) ?? ""
        return id.isEmpty ? nil : id
    }

    var clientID: String? { customClientID ?? Self.bundledClientID }
    var hasBundledClient: Bool { Self.bundledClientID != nil }

    func saveClientID(_ id: String) {
        UserDefaults.standard.set(id.trimmingCharacters(in: .whitespaces), forKey: Self.customClientKey)
    }

    func signOut(_ account: SlackAccount) {
        if let token = Keychain.get(account.tokenKey) {
            var req = URLRequest(url: URL(string: "https://slack.com/api/auth.revoke")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            HTTP.session.dataTask(with: req).resume()
        }
        Keychain.set(nil, for: account.tokenKey)
        Keychain.set(nil, for: account.refreshKey)
        needsReconnect.remove(account.id)
        accounts.removeAll { $0.id == account.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.accountsKey) }
    }

    // MARK: Sign in

    @discardableResult
    func signIn() async throws -> SlackAccount {
        guard let clientID else { throw AuthError.missingClient }
        let verifier = GoogleAuth.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = GoogleAuth.randomURLSafe(24)

        let server = LoopbackServer()
        _ = try await server.start(port: Self.port)

        var comps = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "user_scope", value: Self.userScope),
            .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        BrowserLauncher.open(comps.url!)

        let callback = try await server.waitForCallback()
        let items = callback.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw AuthError.denied(error) }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.badResponse("missing code")
        }

        let json = try await post("oauth.v2.access", form: [
            "client_id": clientID,
            "code": code,
            "redirect_uri": Self.redirect,
            "code_verifier": verifier,
        ])
        guard let user = json["authed_user"] as? [String: Any],
              let token = user["access_token"] as? String,
              let team = json["team"] as? [String: Any], let teamID = team["id"] as? String else {
            throw AuthError.badResponse("no user token")
        }
        var account = accounts.first { $0.teamID == teamID }
            ?? SlackAccount(teamID: teamID, teamName: team["name"] as? String ?? "Slack",
                            userID: user["id"] as? String ?? "", clientID: clientID)
        account.clientID = clientID
        store(token: token, refresh: user["refresh_token"] as? String, expiresIn: user["expires_in"] as? Double, for: &account)
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        needsReconnect.remove(account.id)
        save()
        return account
    }

    private func store(token: String, refresh: String?, expiresIn: Double?, for account: inout SlackAccount) {
        Keychain.set(token, for: account.tokenKey)
        if let refresh { Keychain.set(refresh, for: account.refreshKey) }
        account.tokenExpiry = expiresIn.map { Date().addingTimeInterval($0) }
    }

    /// The user token, refreshed first when it's about to expire.
    func validToken(for account: SlackAccount) async throws -> String {
        guard let token = Keychain.get(account.tokenKey) else { throw AuthError.notSignedIn }
        guard let until = account.tokenExpiry, until.timeIntervalSinceNow < 60 else { return token }
        guard let refresh = Keychain.get(account.refreshKey) else {
            needsReconnect.insert(account.id)
            throw AuthError.notSignedIn
        }
        do {
            let json = try await post("oauth.v2.access", form: [
                "client_id": account.clientID,
                "grant_type": "refresh_token",
                "refresh_token": refresh,
            ])
            // A refreshed user token can come back at the top level or under authed_user.
            let user = json["authed_user"] as? [String: Any] ?? json
            guard let fresh = user["access_token"] as? String else { throw AuthError.badResponse("no token") }
            var updated = account
            store(token: fresh, refresh: user["refresh_token"] as? String, expiresIn: user["expires_in"] as? Double, for: &updated)
            if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = updated; save() }
            needsReconnect.remove(account.id)
            return fresh
        } catch {
            // Refresh tokens from PKCE apps expire after 30 days: sign in again.
            needsReconnect.insert(account.id)
            throw error
        }
    }

    private func post(_ method: String, form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await HTTP.session.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.badResponse("bad JSON") }
        guard json["ok"] as? Bool == true else { throw AuthError.badResponse(json["error"] as? String ?? "unknown error") }
        return json
    }
}
