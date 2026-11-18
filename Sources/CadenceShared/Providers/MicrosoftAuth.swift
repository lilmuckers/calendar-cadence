import CadenceCore
import CryptoKit
import Foundation
import Observation

/// A signed-in Microsoft account (work/school or personal). The refresh token lives in the Keychain.
struct MicrosoftAccount: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var email: String?
    var clientID: String
    /// Whether the token allows replying to invites (nil = not known yet).
    var canWrite: Bool?

    var refreshKey: String { "microsoft.refreshToken.\(id)" }
    var avatarKey: String { "microsoft-\(id)" }
    var label: String { email ?? "Microsoft account" }
}

/// OAuth 2.0 against the Microsoft identity platform for a public desktop client: system browser,
/// loopback redirect and PKCE, no client secret. Works for Microsoft 365 and personal Outlook.com accounts.
@MainActor
@Observable
final class MicrosoftAuth {
    enum AuthError: LocalizedError {
        case missingClient, denied(String), badResponse(String), notSignedIn, clientChanged

        var errorDescription: String? {
            switch self {
            case .missingClient: "Enter your Microsoft application (client) ID first."
            case .denied(let why): "Microsoft sign-in was cancelled: \(why)"
            case .badResponse(let why): "Microsoft sign-in failed: \(why)"
            case .notSignedIn: "Not signed in to Microsoft."
            case .clientChanged: "This account was connected with a different app registration. Reconnect it."
            }
        }
    }

    static let writeScope = "Calendars.ReadWrite"
    /// MailboxSettings.Read gives category colours; offline_access gives a refresh token.
    static let scope = "openid email profile offline_access User.Read \(writeScope) MailboxSettings.Read"
    private static let authority = "https://login.microsoftonline.com/common/oauth2/v2.0"
    private static let accountsKey = "Cadence.microsoft.accounts"
    private static let customClientKey = "Cadence.microsoft.clientID"

    private(set) var accounts: [MicrosoftAccount] = []
    private(set) var needsReconnect: Set<String> = []
    @ObservationIgnored private var tokens: [String: (token: String, expiry: Date)] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let saved = try? JSONDecoder().decode([MicrosoftAccount].self, from: data) {
            accounts = saved
        }
    }

    // MARK: Client

    /// Injected by scripts/build.sh from MICROSOFT_CLIENT_ID, if set at build time.
    static let bundledClientID: String? = {
        let id = Bundle.main.infoDictionary?["CadenceMicrosoftClientID"] as? String
        return id?.isEmpty == false && id?.hasPrefix("$(") == false ? id : nil
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

    func clearCustomClient() {
        if let custom = customClientID {
            for account in accounts where account.clientID == custom { signOut(account) }
        }
        UserDefaults.standard.removeObject(forKey: Self.customClientKey)
    }

    private func clientID(for account: MicrosoftAccount) -> String? {
        [customClientID, Self.bundledClientID].compactMap { $0 }.first { $0 == account.clientID }
    }

    // MARK: Accounts

    func signOut(_ account: MicrosoftAccount) {
        // Microsoft has no token revocation endpoint for public clients; forgetting the token is enough.
        Keychain.set(nil, for: account.refreshKey)
        AvatarStore.shared.remove(account.avatarKey)
        tokens[account.id] = nil
        needsReconnect.remove(account.id)
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
    }

    func setEmail(_ email: String, for id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].email == nil else { return }
        accounts[i].email = email
        saveAccounts()
    }

    private func setCanWrite(_ value: Bool, for id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].canWrite != value else { return }
        accounts[i].canWrite = value
        saveAccounts()
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.accountsKey) }
    }

    // MARK: Sign in

    #if os(macOS)
    /// Microsoft matches "http://localhost" redirect URIs on any port.
    static func redirectSession() async throws -> OAuthRedirectSession {
        try await LoopbackRedirectSession.start(host: "localhost")
    }
    #else
    /// Add this redirect under the app registration's "iOS / macOS" platform.
    static var redirectURI: String { "msauth.\(Bundle.main.bundleIdentifier ?? "com.cadence.companion")://auth" }

    static func redirectSession() async throws -> OAuthRedirectSession {
        WebRedirectSession(redirectURI: redirectURI)
    }
    #endif

    @discardableResult
    func signIn() async throws -> MicrosoftAccount {
        guard let clientID else { throw AuthError.missingClient }
        let verifier = GoogleAuth.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = GoogleAuth.randomURLSafe(24)

        let session = try await Self.redirectSession()
        let redirect = session.redirectURI

        var comps = URLComponents(string: "\(Self.authority)/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]
        let callback = try await session.authorize(comps.url!)
        let items = callback.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw AuthError.denied(items.first { $0.name == "error_description" }?.value ?? error)
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.badResponse("missing code")
        }

        let response = try await tokenRequest([
            "client_id": clientID,
            "scope": Self.scope,
            "code": code,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = response.refresh_token else { throw AuthError.badResponse("no refresh token") }
        let email = response.id_token.flatMap(JWT.email(in:))

        var account = accounts.first { $0.email != nil && $0.email?.lowercased() == email?.lowercased() }
            ?? MicrosoftAccount(email: email, clientID: clientID)
        account.clientID = clientID
        account.canWrite = response.scope.map { $0.contains(Self.writeScope) }
        Keychain.set(refresh, for: account.refreshKey)
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        needsReconnect.remove(account.id)
        tokens[account.id] = (response.access_token, Date().addingTimeInterval(response.expires_in ?? 3600))
        saveAccounts()
        return account
    }

    func validAccessToken(for account: MicrosoftAccount) async throws -> String {
        if let cached = tokens[account.id], cached.expiry.timeIntervalSinceNow > 60 { return cached.token }
        guard let refresh = Keychain.get(account.refreshKey) else { throw AuthError.notSignedIn }
        guard let clientID = clientID(for: account) else {
            needsReconnect.insert(account.id)
            throw AuthError.clientChanged
        }
        do {
            let response = try await tokenRequest([
                "client_id": clientID,
                "scope": Self.scope,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
            // Microsoft rotates refresh tokens: keep the newest one.
            if let rotated = response.refresh_token { Keychain.set(rotated, for: account.refreshKey) }
            tokens[account.id] = (response.access_token, Date().addingTimeInterval(response.expires_in ?? 3600))
            needsReconnect.remove(account.id)
            if let scope = response.scope { setCanWrite(scope.contains(Self.writeScope), for: account.id) }
            return response.access_token
        } catch TokenError.invalidGrant {
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
        var req = URLRequest(url: URL(string: "\(Self.authority)/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP error"
            if form["grant_type"] == "refresh_token", body.contains("invalid_grant") { throw TokenError.invalidGrant }
            throw AuthError.badResponse(body)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}
