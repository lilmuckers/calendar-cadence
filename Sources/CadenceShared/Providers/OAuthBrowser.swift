import Foundation
#if os(macOS)
import AppKit
import Network
#else
import AuthenticationServices
import UIKit
#endif

/// One OAuth authorization round trip: open the provider's page in a browser, wait for the redirect.
/// macOS uses the system browser and a loopback redirect; iOS uses ASWebAuthenticationSession and a
/// custom URL scheme redirect.
@MainActor
protocol OAuthRedirectSession: AnyObject {
    var redirectURI: String { get }
    /// Opens `url` and returns the redirect's components (with `code`/`state` or `error`).
    func authorize(_ url: URL) async throws -> URLComponents
}

#if os(macOS)
/// System browser + one-shot loopback server. `host` is what goes in the redirect URI
/// ("127.0.0.1" for Google, "localhost" for Microsoft); the server listens on both.
@MainActor
final class LoopbackRedirectSession: OAuthRedirectSession {
    private let server: LoopbackServer
    let redirectURI: String

    private init(server: LoopbackServer, redirectURI: String) {
        self.server = server
        self.redirectURI = redirectURI
    }

    static func start(host: String) async throws -> LoopbackRedirectSession {
        let server = LoopbackServer()
        let port = try await server.start()
        return LoopbackRedirectSession(server: server, redirectURI: "http://\(host):\(port)")
    }

    func authorize(_ url: URL) async throws -> URLComponents {
        NSWorkspace.shared.open(url)
        return try await server.waitForCallback()
    }
}

/// One-shot HTTP server on the loopback interface that captures the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cadence.oauth.loopback")
    private var listener: NWListener?

    /// `port` nil picks a free one; Slack needs a fixed port its redirect page forwards to.
    func start(port fixed: UInt16? = nil) async throws -> UInt16 {
        // Listen on every loopback address (IPv4 and IPv6) so both http://127.0.0.1 and
        // http://localhost redirects reach us; nothing off this Mac can connect.
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: fixed.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
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
                        ? OAuthLandingPage.html(error: comps?.queryItems?.first { $0.name == "error" }?.value)
                        : ""
                    let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    if isCallback, let comps { finish(.success(comps)) }
                }
            }
        }
    }
}

#endif

#if os(iOS)
/// ASWebAuthenticationSession with a custom-scheme redirect (e.g. "com.googleusercontent.apps.123:/oauth2redirect").
@MainActor
final class WebRedirectSession: NSObject, OAuthRedirectSession, ASWebAuthenticationPresentationContextProviding {
    let redirectURI: String
    private var session: ASWebAuthenticationSession?

    init(redirectURI: String) { self.redirectURI = redirectURI }

    func authorize(_ url: URL) async throws -> URLComponents {
        let scheme = URL(string: redirectURI)?.scheme
        return try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback, let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false) {
                    cont.resume(returning: comps)
                } else {
                    cont.resume(throwing: error ?? URLError(.cancelled))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { cont.resume(throwing: URLError(.cannotOpenFile)) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
#endif
