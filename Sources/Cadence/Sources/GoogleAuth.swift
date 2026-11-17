import AppKit
import CryptoKit
import Foundation
import Network

/// OAuth 2.0 for installed apps: system browser + loopback redirect + PKCE.
/// Uses the user's own "Desktop app" OAuth client from Google Cloud Console.
@MainActor
final class GoogleAuth {
    struct Credentials: Equatable {
        var clientID: String
        var clientSecret: String
    }

    enum AuthError: LocalizedError {
        case missingCredentials, denied(String), badResponse(String), notSignedIn

        var errorDescription: String? {
            switch self {
            case .missingCredentials: "Enter your Google OAuth client ID and secret first."
            case .denied(let why): "Google sign-in was cancelled: \(why)"
            case .badResponse(let why): "Google sign-in failed: \(why)"
            case .notSignedIn: "Not signed in to Google."
            }
        }
    }

    static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    private static let refreshKey = "google.refreshToken"
    private static let secretKey = "google.clientSecret"

    private var accessToken: String?
    private var expiry = Date.distantPast

    /// The client in use: one the user entered in Settings wins over the one built into the app.
    var credentials: Credentials? { customCredentials ?? Self.bundledCredentials }

    /// A client the user entered themselves (Settings → Accounts → "Use my own OAuth client").
    var customCredentials: Credentials? {
        let id = UserDefaults.standard.string(forKey: "Cadence.google.clientID") ?? ""
        let secret = Keychain.get(Self.secretKey) ?? ""
        return id.isEmpty || secret.isEmpty ? nil : Credentials(clientID: id, clientSecret: secret)
    }

    /// Injected by scripts/build.sh from GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET, if set at build time.
    static let bundledCredentials: Credentials? = {
        let info = Bundle.main.infoDictionary
        guard let id = info?["CadenceGoogleClientID"] as? String, !id.isEmpty,
              let secret = info?["CadenceGoogleClientSecret"] as? String, !secret.isEmpty else { return nil }
        return Credentials(clientID: id, clientSecret: secret)
    }()

    var hasBundledClient: Bool { Self.bundledCredentials != nil }

    func saveCredentials(clientID: String, clientSecret: String) {
        UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "Cadence.google.clientID")
        Keychain.set(clientSecret.trimmingCharacters(in: .whitespaces), for: Self.secretKey)
    }

    /// Go back to the built-in client. Signs out, since refresh tokens belong to the client that issued them.
    func clearCustomCredentials() {
        signOut()
        UserDefaults.standard.removeObject(forKey: "Cadence.google.clientID")
        Keychain.set(nil, for: Self.secretKey)
    }

    var isSignedIn: Bool { Keychain.get(Self.refreshKey) != nil }

    func signOut() {
        if let token = Keychain.get(Self.refreshKey),
           let url = URL(string: "https://oauth2.googleapis.com/revoke?token=\(token)") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
        Keychain.set(nil, for: Self.refreshKey)
        accessToken = nil
        expiry = .distantPast
    }

    // MARK: Sign in

    func signIn() async throws {
        guard let creds = credentials else { throw AuthError.missingCredentials }
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(24)

        let server = LoopbackServer()
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: creds.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(comps.url!)

        let callback = try await server.waitForCallback()
        let items = callback.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw AuthError.denied(error) }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.badResponse("missing code")
        }

        let tokens = try await tokenRequest([
            "code": code,
            "client_id": creds.clientID,
            "client_secret": creds.clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = tokens.refresh_token else { throw AuthError.badResponse("no refresh token") }
        Keychain.set(refresh, for: Self.refreshKey)
        store(tokens)
    }

    /// A valid access token, refreshing it when it is about to expire.
    func validAccessToken() async throws -> String {
        if let accessToken, expiry.timeIntervalSinceNow > 60 { return accessToken }
        guard let creds = credentials, let refresh = Keychain.get(Self.refreshKey) else { throw AuthError.notSignedIn }
        let tokens = try await tokenRequest([
            "client_id": creds.clientID,
            "client_secret": creds.clientSecret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        store(tokens)
        return tokens.access_token
    }

    // MARK: Helpers

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Double?
        var refresh_token: String?
    }

    private func store(_ t: TokenResponse) {
        accessToken = t.access_token
        expiry = Date().addingTimeInterval(t.expires_in ?? 3600)
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if (response as? HTTPURLResponse)?.statusCode == 400, form["grant_type"] == "refresh_token" {
                Keychain.set(nil, for: Self.refreshKey) // revoked or expired: force re-sign-in
            }
            throw AuthError.badResponse(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP server on 127.0.0.1 that captures the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cadence.oauth.loopback")
    private var listener: NWListener?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        return try await withCheckedThrowingContinuation { cont in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { cont.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
    }

    /// Waits (up to 5 minutes) for the browser to hit the redirect URL.
    func waitForCallback() async throws -> URLComponents {
        guard let listener else { throw URLError(.cannotConnectToHost) }
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            let once = Once()
            let finish: @Sendable (Result<URLComponents, Error>) -> Void = { result in
                once.run { cont.resume(with: result) }
            }
            queue.asyncAfter(deadline: .now() + 300) { finish(.failure(URLError(.timedOut))) }
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let comps = URLComponents(string: "http://127.0.0.1\(path)")
                    let isCallback = comps?.queryItems?.contains { $0.name == "code" || $0.name == "error" } == true
                    let body = isCallback
                        ? "<html><body style='font:16px -apple-system;text-align:center;padding-top:20vh'><h2>Cadence is connected 🎉</h2><p>You can close this tab.</p></body></html>"
                        : ""
                    let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    if isCallback, let comps { finish(.success(comps)) }
                }
            }
        }
    }
}

/// Runs a closure at most once, from any thread (continuations must resume exactly once).
private final class Once: @unchecked Sendable {
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
