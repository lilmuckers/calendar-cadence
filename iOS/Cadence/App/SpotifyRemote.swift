import CadenceCore
import Foundation
import Observation
import SpotifyiOS
import UIKit

/// Spotify on this phone, through Spotify's App Remote SDK: track, artwork and controls for the
/// desk display. Talks to the Spotify app itself (it has to be installed, and running for a
/// connection). The first time, connecting hops over to Spotify for a moment to approve (only
/// ever from a tap). That gives a session with a refresh token (PKCE, no secret or server), so
/// when the hour-long access token lapses Cadence renews it quietly instead of asking again.
@MainActor
@Observable
final class SpotifyRemote: NSObject {
    static let redirectURL = URL(string: "cadence-companion://spotify-callback")!
    private static let sessionAccount = "spotify.session"
    /// Before sessions: a bare one-hour token. Cleared on launch.
    private static let legacyTokenAccount = "spotify.appRemote.token"

    private(set) var connected = false
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var artwork: UIImage?
    private(set) var trackURI: String?
    private(set) var isPlaying = false
    private(set) var canSkip = true
    /// When playback last stopped, so a pause doesn't make the controls vanish under your finger.
    private(set) var stoppedAt: Date?
    /// No usable token: the user needs to tap Connect (which opens Spotify briefly).
    private(set) var needsAuthorization: Bool
    /// Why the last approval or connection didn't work, shown in Settings and on the desk card.
    private(set) var lastError: String?

    /// The Spotify developer app Cadence talks to as. Each person brings their own (Settings →
    /// Spotify app), since a single app in Spotify's development mode only works for the 25
    /// accounts its owner lists. A build-time one (Local.xcconfig → SPOTIFY_CLIENT_ID) is only a
    /// fallback for development builds.
    private(set) var clientID: String?
    /// The user's own client ID, if they entered one.
    private(set) var customClientID: String?
    @ObservationIgnored private let bundledClientID: String?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var wantConnected = false
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var renewing = false
    @ObservationIgnored private var lastRenew: Date?

    @ObservationIgnored private var configuration: SPTConfiguration?
    @ObservationIgnored private var remote: SPTAppRemote?
    @ObservationIgnored private var sessions: SPTSessionManager?

    private static let clientIDKey = "Cadence.spotify.clientID"
    /// Which client ID the saved session belongs to (its refresh token only works for that one).
    private static let sessionClientAccount = "spotify.session.clientID"

    override init() {
        let bundled = Self.normalized(Bundle.main.object(forInfoDictionaryKey: "CadenceSpotifyClientID") as? String)
        let custom = Self.normalized(UserDefaults.standard.string(forKey: Self.clientIDKey))
        let active = custom ?? bundled
        bundledClientID = bundled
        customClientID = custom
        clientID = active
        Keychain.set(nil, for: Self.legacyTokenAccount)
        Keychain.set(nil, for: Self.legacyTokenAccount + ".date")
        // A session made with another client ID can't be renewed with this one: drop it.
        if let saved = Keychain.get(Self.sessionClientAccount), saved != active {
            Keychain.set(nil, for: Self.sessionAccount)
            Keychain.set(nil, for: Self.sessionClientAccount)
        }
        needsAuthorization = Self.storedSession() == nil
        super.init()
        configure()
    }

    private static func normalized(_ id: String?) -> String? {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Spotify client IDs are 32 hex characters.
    static func isValidClientID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 32 && trimmed.allSatisfy(\.isHexDigit)
    }

    /// (Re)builds the SDK objects for the current client ID.
    private func configure() {
        remote?.delegate = nil
        configuration = nil
        remote = nil
        sessions = nil
        guard let clientID else { return }
        let config = SPTConfiguration(clientID: clientID, redirectURL: Self.redirectURL)
        // Approving carries on with whatever was playing (or resumes the last track).
        config.playURI = ""
        configuration = config
        let remote = SPTAppRemote(configuration: config, logLevel: .error)
        remote.delegate = self
        self.remote = remote
        let manager = SPTSessionManager(configuration: config, delegate: self)
        manager.session = Self.storedSession()
        sessions = manager
    }

    /// Switches to the user's own Spotify developer app (nil or empty goes back to the built-in
    /// one, if there is one). Signs out, since the old session belongs to the old app.
    func setClientID(_ id: String?) {
        let id = Self.normalized(id)
        guard id != customClientID else { return }
        signOut()
        customClientID = id
        if let id { UserDefaults.standard.set(id, forKey: Self.clientIDKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.clientIDKey) }
        clientID = id ?? bundledClientID
        lastError = nil
        configure()
    }

    /// There's a built-in client ID to fall back on (development builds).
    var hasBundledClientID: Bool { bundledClientID != nil }

    private static func storedSession() -> SPTSession? {
        guard let text = Keychain.get(sessionAccount), let data = Data(base64Encoded: text) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: SPTSession.self, from: data)
    }

    private func save(_ session: SPTSession?) {
        let data = session.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        Keychain.set(data?.base64EncodedString(), for: Self.sessionAccount)
        Keychain.set(data == nil ? nil : clientID, for: Self.sessionClientAccount)
    }

    /// Has a Spotify client ID (the user's own, or a development build's).
    var isAvailable: Bool { clientID != nil }

    func showsControls(now: Date) -> Bool {
        connected && (isPlaying || stoppedAt.map { now.timeIntervalSince($0) < 12 } ?? false)
    }

    // MARK: Connection

    /// Quietly connects with the saved session when Spotify looks to be playing, renewing its
    /// token first if it has lapsed. Never opens Spotify.
    func connectIfPossible() {
        guard isAvailable, !connected, !needsAuthorization, let session = sessions?.session else { return }
        if session.isExpired || session.expirationDate.timeIntervalSinceNow < 60 { renew(); return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 15 { return }
        connect(token: session.accessToken)
    }

    /// A fresh access token from the refresh token (network, no app switch).
    private func renew() {
        guard let sessions, sessions.session != nil, !renewing else { return }
        if let lastRenew, Date().timeIntervalSince(lastRenew) < 30 { return }
        lastRenew = Date()
        renewing = true
        sessions.renewSession()
    }

    private func connect(token: String?) {
        guard let remote, !connecting, !remote.isConnected else { return }
        lastAttempt = Date()
        wantConnected = true
        connecting = true
        remote.connectionParameters.accessToken = token
        remote.connect()
    }

    /// From a tap: hop to Spotify to approve (it carries on with whatever was playing, or resumes
    /// the last track), then come back here connected.
    func authorize() {
        guard let sessions else { return }
        wantConnected = true
        lastError = nil
        // The SDK's installed check (canOpenURL on "spotify:") can say no with Spotify right there,
        // which sent people to the App Store. Don't trust a no: open Spotify directly instead, and
        // the SDK signs in on the web if it really isn't installed.
        let installed = sessions.isSpotifyAppInstalled
        if !installed { NSLog("Cadence: Spotify installed check said no; opening it directly") }
        sessions.initiateSession(with: .appRemoteControl,
                                 options: installed ? .clientOnly : .spotifySchemeNotRegistered, campaign: nil)
    }

    /// Spotify's redirect back to Cadence. True if it was ours (the session manager takes it from
    /// there: exchanging the code for tokens and telling the delegate).
    func handle(_ url: URL) -> Bool {
        guard url.scheme == Self.redirectURL.scheme, url.host == Self.redirectURL.host, let sessions else { return false }
        if !sessions.application(UIApplication.shared, open: url, options: [:]) {
            lastError = "Spotify didn't send back access."
            NSLog("Cadence: Spotify redirect not understood: \(url.scheme ?? "")://\(url.host ?? "")\(url.path)")
        }
        return true
    }

    /// Spotify asks apps to let go when they leave the foreground.
    func suspend() {
        guard let remote, remote.isConnected else { return }
        remote.disconnect()
    }

    func resume() {
        lastAttempt = nil
        if wantConnected { connectIfPossible() }
    }

    func signOut() {
        save(nil)
        sessions?.session = nil
        needsAuthorization = true
        wantConnected = false
        remote?.disconnect()
        clear()
    }

    // MARK: Controls

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        remote?.playerAPI?.resume(nil)
        isPlaying = true
    }

    func pause() {
        remote?.playerAPI?.pause(nil)
        if isPlaying { stoppedAt = Date() }
        isPlaying = false
    }

    func next() { remote?.playerAPI?.skip(toNext: nil) }
    func previous() { remote?.playerAPI?.skip(toPrevious: nil) }

    /// Meeting alert: stop it outright (and don't linger on screen).
    func pauseForMeeting() -> Bool {
        guard connected, isPlaying else { return false }
        pause()
        stoppedAt = nil
        return true
    }

    func companionMedia(includeArtwork: Bool) -> CompanionMedia? {
        guard connected, isPlaying else { return nil }
        return CompanionMedia(app: .spotify, title: title, artist: artist, isPlaying: true,
                              artwork: includeArtwork ? artwork?.jpegData(compressionQuality: 0.7) : nil,
                              trackID: trackURI, canSkip: canSkip)
    }

    // MARK: State

    private func didConnect() {
        connected = true
        connecting = false
        needsAuthorization = false
        lastError = nil
        guard let player = remote?.playerAPI else { return }
        player.delegate = self
        player.subscribe(toPlayerState: { [weak self] result, error in
            Task { @MainActor in
                if let error { NSLog("Cadence: Spotify subscribe failed: \(error.localizedDescription)") }
                if let state = result as? SPTAppRemotePlayerState { self?.apply(state) }
            }
        })
        // Subscribing only reports changes, so ask for what's playing now.
        refreshState()
    }

    @ObservationIgnored private var lastRefresh: Date?

    /// Asks Spotify what's playing (on connect, and while connected with nothing known yet).
    func refreshState() {
        guard connected, let player = remote?.playerAPI else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 3 { return }
        lastRefresh = Date()
        player.getPlayerState { [weak self] result, error in
            Task { @MainActor in
                if let error { NSLog("Cadence: Spotify player state failed: \(error.localizedDescription)") }
                if let state = result as? SPTAppRemotePlayerState { self?.apply(state) }
            }
        }
    }

    private func apply(_ state: SPTAppRemotePlayerState) {
        let playing = !state.isPaused
        if isPlaying && !playing { stoppedAt = Date() }
        isPlaying = playing
        canSkip = state.playbackRestrictions.canSkipNext || state.playbackRestrictions.canSkipPrevious
        let track = state.track
        title = track.name
        artist = track.artist.name
        guard track.uri != trackURI else { return }
        trackURI = track.uri
        artwork = nil
        remote?.imageAPI?.fetchImage(forItem: track, with: CGSize(width: 160, height: 160)) { [weak self] result, _ in
            Task { @MainActor in
                guard self?.trackURI == track.uri else { return }
                self?.artwork = result as? UIImage
            }
        }
    }

    private func clear() {
        connected = false
        isPlaying = false
        title = nil
        artist = nil
        artwork = nil
        trackURI = nil
    }
}

extension SpotifyRemote: SPTSessionManagerDelegate {
    nonisolated func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        Task { @MainActor in self.gotSession(session) }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        Task { @MainActor in self.gotSession(session) }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        let message = error.localizedDescription
        let offline = (error as NSError).domain == NSURLErrorDomain
        Task { @MainActor in
            NSLog("Cadence: Spotify session failed: \(message)")
            self.lastError = offline ? "Couldn't reach Spotify to renew access." : "Spotify said: \(message)"
            // A refresh that Spotify turned down (revoked, or the app's settings changed) needs a tap;
            // being offline just waits for the next try.
            if self.renewing && !offline { self.needsAuthorization = true }
            self.renewing = false
        }
    }
}

extension SpotifyRemote {
    fileprivate func gotSession(_ session: SPTSession) {
        renewing = false
        save(session)
        needsAuthorization = false
        lastError = nil
        lastAttempt = nil
        connect(token: session.accessToken)
    }
}

extension SpotifyRemote: SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in self.didConnect() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor in
            self.clear()
            self.connecting = false
            self.lastError = error?.localizedDescription ?? "Couldn't connect to Spotify."
            // Spotify not running fails too, so don't give up on the session: if its token has
            // lapsed, renew it (quietly) and the next attempt uses the new one.
            if let error { NSLog("Cadence: Spotify connection failed: \(error.localizedDescription)") }
            if let session = self.sessions?.session, session.isExpired || session.expirationDate.timeIntervalSinceNow < 60 {
                self.renew()
            }
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor in
            self.clear()
            self.connecting = false
        }
    }

    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        Task { @MainActor in self.apply(playerState) }
    }
}
