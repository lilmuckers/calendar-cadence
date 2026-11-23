import CryptoKit
import Foundation
import CadenceCore
import Observation

/// A signed-in Google account. The refresh token lives in the Keychain under `refreshKey`.
struct GoogleAccount: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var email: String?
    /// The OAuth client that issued this account's refresh token (tokens only work with that client).
    var clientID: String
    /// Whether the token allows replying to invites and setting colours (nil = not known yet).
    var canWrite: Bool?
    /// Profile photo URL from the ID token's `picture` claim.
    var pictureURL: String?
    /// The user turned on "Running late" messages for this account.
    var messagingEnabled: Bool?
    /// Granted: send Gmail as you / post in Google Chat as you.
    var canSendMail: Bool?
    var canChat: Bool?

    var refreshKey: String { "google.refreshToken.\(id)" }
    var avatarKey: String { "google-\(id)" }
    var label: String { email ?? "Google account" }
}

/// OAuth 2.0 for installed apps (system browser + loopback redirect + PKCE), for any number of
/// Google accounts. Uses the client built into the app, or one the user entered in Settings.
@MainActor
@Observable
final class GoogleAuth {
    struct Credentials: Equatable {
        var clientID: String
        /// Empty for iOS clients, which have no secret.
        var clientSecret: String

        func form(_ fields: [String: String]) -> [String: String] {
            var out = fields
            out["client_id"] = clientID
            if !clientSecret.isEmpty { out["client_secret"] = clientSecret }
            return out
        }
    }

    enum AuthError: LocalizedError {
        case missingCredentials, denied(String), badResponse(String), notSignedIn, clientChanged

        var errorDescription: String? {
            switch self {
            case .missingCredentials: "Enter your Google OAuth client ID and secret first."
            case .denied(let why): "Google sign-in was cancelled: \(why)"
            case .badResponse(let why): "Google sign-in failed: \(why)"
            case .notSignedIn: "Not signed in to Google."
            case .clientChanged: "This account was connected with a different OAuth client. Reconnect it."
            }
        }
    }

    static let writeScope = "https://www.googleapis.com/auth/calendar.events"
    /// The narrowest pair that works: calendar.events reads (and, on a click, replies to or colours) events on every
    /// calendar, and calendarlist.readonly lists the calendars so the user can choose which to show.
    /// calendar.readonly is broader (settings, sharing, free/busy) and Google's verification rejects it here.
    static let listScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    static let scope = "openid email profile \(listScope) \(writeScope)"
    /// Asked for only when "Running late" messages are turned on, and only with a client the user brought
    /// themselves: it's a *restricted* scope, so the built-in client (which goes through Google's verification)
    /// never asks for it.
    static let mailScope = "https://www.googleapis.com/auth/gmail.send"
    /// Find or start a DM/group chat, then post in it.
    static let chatScopes = "https://www.googleapis.com/auth/chat.spaces.readonly https://www.googleapis.com/auth/chat.spaces.create https://www.googleapis.com/auth/chat.messages.create"

    /// Whether accounts from this client may send Gmail: any client except the built-in one.
    static func allowsMail(clientID: String) -> Bool { clientID != bundledCredentials?.clientID }

    static func messagingScope(clientID: String) -> String {
        "\(scope) \(chatScopes)" + (allowsMail(clientID: clientID) ? " \(mailScope)" : "")
    }

    /// Granted Gmail send, and allowed to use it (a built-in-client token may still carry an old grant).
    private static func canSendMail(scope: String, clientID: String) -> Bool {
        scope.contains(mailScope) && allowsMail(clientID: clientID)
    }
    private static let accountsKey = "Cadence.google.accounts"
    private static let legacyRefreshKey = "google.refreshToken"
    private static let secretKey = "google.clientSecret"

    private(set) var accounts: [GoogleAccount] = []
    /// Accounts whose refresh token was rejected (revoked, or expired in Testing mode).
    private(set) var needsReconnect: Set<String> = []
    @ObservationIgnored private var tokens: [String: (token: String, expiry: Date)] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let saved = try? JSONDecoder().decode([GoogleAccount].self, from: data) {
            accounts = saved
        }
        migrateSingleAccount()
    }

    // MARK: Clients

    /// The client used for new sign-ins: one the user entered in Settings wins over the built-in one.
    var credentials: Credentials? { customCredentials ?? Self.bundledCredentials }

    /// A client the user entered themselves (Settings → Accounts → "Use my own OAuth client").
    var customCredentials: Credentials? {
        let id = UserDefaults.standard.string(forKey: "Cadence.google.clientID") ?? ""
        let secret = Keychain.get(Self.secretKey) ?? ""
        return id.isEmpty || (Self.needsSecret && secret.isEmpty) ? nil : Credentials(clientID: id, clientSecret: secret)
    }

    #if os(macOS)
    /// Desktop clients use a (non-confidential) secret; iOS clients don't have one.
    static let needsSecret = true

    /// Injected by scripts/build.sh from GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET, if set at build time.
    static let bundledCredentials: Credentials? = {
        let info = Bundle.main.infoDictionary
        guard let id = info?["CadenceGoogleClientID"] as? String, !id.isEmpty,
              let secret = info?["CadenceGoogleClientSecret"] as? String, !secret.isEmpty else { return nil }
        return Credentials(clientID: id, clientSecret: secret)
    }()

    static func redirectSession(clientID: String) async throws -> OAuthRedirectSession {
        try await LoopbackRedirectSession.start(host: "127.0.0.1")
    }
    #else
    static let needsSecret = false

    /// From GOOGLE_IOS_CLIENT_PREFIX (an "iOS" type client) in iOS/Config/Local.xcconfig.
    static let bundledCredentials: Credentials? = {
        guard let prefix = Bundle.main.infoDictionary?["CadenceGoogleIOSClientPrefix"] as? String,
              !prefix.isEmpty, !prefix.hasPrefix("$(") else { return nil }
        return Credentials(clientID: prefix + ".apps.googleusercontent.com", clientSecret: "")
    }()

    /// iOS clients redirect to the reversed client ID: com.googleusercontent.apps.<id>:/oauth2redirect.
    static func redirectScheme(clientID: String) -> String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    static func redirectSession(clientID: String) async throws -> OAuthRedirectSession {
        WebRedirectSession(redirectURI: redirectScheme(clientID: clientID) + ":/oauth2redirect")
    }
    #endif

    var hasBundledClient: Bool { Self.bundledCredentials != nil }

    func saveCredentials(clientID: String, clientSecret: String) {
        UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "Cadence.google.clientID")
        Keychain.set(clientSecret.trimmingCharacters(in: .whitespaces), for: Self.secretKey)
    }

    /// Go back to the built-in client. Accounts connected through the custom client are signed out,
    /// since refresh tokens only work with the client that issued them.
    func clearCustomCredentials() {
        if let custom = customCredentials {
            for account in accounts where account.clientID == custom.clientID { signOut(account) }
        }
        UserDefaults.standard.removeObject(forKey: "Cadence.google.clientID")
        Keychain.set(nil, for: Self.secretKey)
    }

    /// The client that issued an account's token, if it's still available.
    private func credentials(for account: GoogleAccount) -> Credentials? {
        [customCredentials, Self.bundledCredentials].compactMap { $0 }.first { $0.clientID == account.clientID }
    }

    // MARK: Accounts

    var isSignedIn: Bool { !accounts.isEmpty }

    func signOut(_ account: GoogleAccount) {
        if let token = Keychain.get(account.refreshKey),
           let url = URL(string: "https://oauth2.googleapis.com/revoke?token=\(token)") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            HTTP.session.dataTask(with: req).resume()
        }
        Keychain.set(nil, for: account.refreshKey)
        AvatarStore.shared.remove(account.avatarKey)
        tokens[account.id] = nil
        needsReconnect.remove(account.id)
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
    }

    /// Fill in an email learned later (e.g. from the primary calendar of a migrated account).
    func setEmail(_ email: String, for id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].email == nil else { return }
        accounts[i].email = email
        saveAccounts()
    }

    func setPicture(_ url: String, for id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].pictureURL != url else { return }
        accounts[i].pictureURL = url
        saveAccounts()
    }

    func setCanWrite(_ value: Bool, for id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].canWrite != value else { return }
        accounts[i].canWrite = value
        saveAccounts()
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.accountsKey) }
    }

    /// Earlier versions stored one token under a fixed key; turn it into the first account.
    private func migrateSingleAccount() {
        guard let legacy = Keychain.get(Self.legacyRefreshKey) else { return }
        let account = GoogleAccount(email: nil, clientID: credentials?.clientID ?? "")
        Keychain.set(legacy, for: account.refreshKey)
        Keychain.set(nil, for: Self.legacyRefreshKey)
        accounts.append(account)
        saveAccounts()
    }

    // MARK: Sign in

    /// Opens Google's account chooser and adds (or reconnects) whichever account the user picks.
    /// Turn "Running late" messages on for an account: signs in again asking for Chat (and Gmail, with your own client).
    func enableMessaging(_ account: GoogleAccount) async throws {
        _ = try await signIn(messaging: true, loginHint: account.email)
    }

    func disableMessaging(_ account: GoogleAccount) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i].messagingEnabled = false
        saveAccounts()
    }

    @discardableResult
    func signIn(messaging: Bool = false, loginHint: String? = nil) async throws -> GoogleAccount {
        guard let creds = credentials else { throw AuthError.missingCredentials }
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(24)

        let session = try await Self.redirectSession(clientID: creds.clientID)
        let redirect = session.redirectURI

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: creds.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: messaging ? Self.messagingScope(clientID: creds.clientID) : Self.scope),
            // Keep anything granted earlier (e.g. Gmail send) when signing in again.
            .init(name: "include_granted_scopes", value: "true"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            // Always show the account chooser so a second account can be added.
            .init(name: "prompt", value: "select_account consent"),
        ] + (loginHint.map { [.init(name: "login_hint", value: $0)] } ?? [])
        let callback = try await session.authorize(comps.url!)
        let items = callback.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw AuthError.denied(error) }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.badResponse("missing code")
        }

        let response = try await tokenRequest(creds.form([
            "code": code,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]))
        guard let refresh = response.refresh_token else { throw AuthError.badResponse("no refresh token") }
        let email = response.id_token.flatMap(JWT.email(in:))

        // Same Google account signing in again replaces its old token instead of adding a duplicate.
        var account = accounts.first { $0.email != nil && $0.email == email }
            ?? GoogleAccount(email: email, clientID: creds.clientID)
        account.clientID = creds.clientID
        account.canWrite = response.scope.map { $0.contains(Self.writeScope) }
        account.pictureURL = response.id_token.flatMap { JWT.payload($0)?["picture"] as? String } ?? account.pictureURL
        if messaging { account.messagingEnabled = true }
        if let scope = response.scope {
            account.canSendMail = Self.canSendMail(scope: scope, clientID: creds.clientID)
            account.canChat = scope.contains("chat.messages.create")
        }
        Keychain.set(refresh, for: account.refreshKey)
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        needsReconnect.remove(account.id)
        tokens[account.id] = (response.access_token, Date().addingTimeInterval(response.expires_in ?? 3600))
        saveAccounts()
        return account
    }

    /// A valid access token for the account, refreshing it when it is about to expire.
    func validAccessToken(for account: GoogleAccount) async throws -> String {
        if let cached = tokens[account.id], cached.expiry.timeIntervalSinceNow > 60 { return cached.token }
        guard let refresh = Keychain.get(account.refreshKey) else { throw AuthError.notSignedIn }
        guard let creds = credentials(for: account) else {
            needsReconnect.insert(account.id)
            throw AuthError.clientChanged
        }
        do {
            let response = try await tokenRequest(creds.form([
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ]))
            tokens[account.id] = (response.access_token, Date().addingTimeInterval(response.expires_in ?? 3600))
            needsReconnect.remove(account.id)
            if let scope = response.scope {
                setCanWrite(scope.contains(Self.writeScope), for: account.id)
                if let i = accounts.firstIndex(where: { $0.id == account.id }) {
                    let mail = Self.canSendMail(scope: scope, clientID: creds.clientID), chat = scope.contains("chat.messages.create")
                    if accounts[i].canSendMail != mail || accounts[i].canChat != chat {
                        accounts[i].canSendMail = mail
                        accounts[i].canChat = chat
                        saveAccounts()
                    }
                }
            }
            if let picture = response.id_token.flatMap({ JWT.payload($0)?["picture"] as? String }) { setPicture(picture, for: account.id) }
            return response.access_token
        } catch TokenError.invalidGrant {
            // Revoked, or a Testing-mode token past its 7 days. Keep the account listed so it can be reconnected.
            needsReconnect.insert(account.id)
            throw AuthError.badResponse("access expired — reconnect this account")
        }
    }

    // MARK: Helpers

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Double?
        var refresh_token: String?
        var id_token: String?
        var scope: String?
    }

    private enum TokenError: Error { case invalidGrant }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await HTTP.session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP error"
            if form["grant_type"] == "refresh_token", body.contains("invalid_grant") { throw TokenError.invalidGrant }
            throw AuthError.badResponse(body)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Runs a closure at most once, from any thread (continuations must resume exactly once).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
