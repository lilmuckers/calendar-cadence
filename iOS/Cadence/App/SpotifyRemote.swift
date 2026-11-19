import CadenceCore
import Foundation
import Observation
import SpotifyiOS
import UIKit

/// Spotify on this phone, through Spotify's App Remote SDK: track, artwork and controls for the
/// desk display. Talks to the Spotify app itself (it has to be installed, and running for a
/// connection). The first time — and again whenever the access token has lapsed — connecting
/// hops over to Spotify for a moment to approve, so that only ever happens from a tap.
@MainActor
@Observable
final class SpotifyRemote: NSObject {
    static let redirectURL = URL(string: "cadence-companion://spotify-callback")!
    private static let tokenAccount = "spotify.appRemote.token"

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

    @ObservationIgnored private let clientID: String?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var wantConnected = false
    @ObservationIgnored private var connecting = false

    @ObservationIgnored private lazy var remote: SPTAppRemote? = {
        guard let clientID else { return nil }
        let config = SPTConfiguration(clientID: clientID, redirectURL: Self.redirectURL)
        let remote = SPTAppRemote(configuration: config, logLevel: .error)
        remote.delegate = self
        return remote
    }()

    override init() {
        let id = (Bundle.main.object(forInfoDictionaryKey: "CadenceSpotifyClientID") as? String)?
            .trimmingCharacters(in: .whitespaces)
        clientID = (id?.isEmpty ?? true) ? nil : id
        needsAuthorization = Keychain.get(Self.tokenAccount) == nil
        super.init()
    }

    /// Built with a Spotify client ID (Local.xcconfig → SPOTIFY_CLIENT_ID).
    var isAvailable: Bool { clientID != nil }

    func showsControls(now: Date) -> Bool {
        connected && (isPlaying || stoppedAt.map { now.timeIntervalSince($0) < 12 } ?? false)
    }

    // MARK: Connection

    /// Quietly connects with the saved token when Spotify looks to be playing. Never opens Spotify.
    func connectIfPossible() {
        guard isAvailable, !connected, !needsAuthorization else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 15 { return }
        connect(token: Keychain.get(Self.tokenAccount))
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
        guard let remote else { return }
        wantConnected = true
        lastError = nil
        remote.authorizeAndPlayURI("") { [weak self] ok in
            guard !ok else { return }
            Task { @MainActor in
                self?.lastError = "Spotify isn't installed on this iPhone."
                self?.openStore()
            }
        }
    }

    /// Spotify's redirect back to Cadence. True if it was ours.
    func handle(_ url: URL) -> Bool {
        guard url.scheme == Self.redirectURL.scheme, url.host == Self.redirectURL.host, let remote else { return false }
        let params = remote.authorizationParameters(from: url)
        if let token = params?[SPTAppRemoteAccessTokenKey] {
            Keychain.set(token, for: Self.tokenAccount)
            Keychain.set(String(Date().timeIntervalSince1970), for: Self.tokenAccount + ".date")
            needsAuthorization = false
            lastError = nil
            connect(token: token)
        } else {
            // Usually the Spotify dashboard: redirect URI or iOS bundle ID not matching this build.
            let error = params?[SPTAppRemoteErrorDescriptionKey] ?? "Spotify didn't send back access."
            lastError = "Spotify said: \(error)"
            NSLog("Cadence: Spotify authorization failed: \(error) (\(url.scheme ?? "")://\(url.host ?? "")\(url.path))")
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
        Keychain.set(nil, for: Self.tokenAccount)
        Keychain.set(nil, for: Self.tokenAccount + ".date")
        needsAuthorization = true
        wantConnected = false
        remote?.disconnect()
        clear()
    }

    private func openStore() {
        UIApplication.shared.open(URL(string: "https://apps.apple.com/app/id\(SPTAppRemote.spotifyItunesItemIdentifier())")!)
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

extension SpotifyRemote: SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in self.didConnect() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor in
            self.clear()
            self.connecting = false
            self.lastError = error?.localizedDescription ?? "Couldn't connect to Spotify."
            // Spotify not running fails too, so only give up on the token once it's surely expired
            // (they last an hour); the next attempt after that asks for a tap.
            if let error { NSLog("Cadence: Spotify connection failed: \(error.localizedDescription)") }
            if let saved = Keychain.get(Self.tokenAccount + ".date").flatMap(Double.init),
               Date().timeIntervalSince1970 - saved > 55 * 60 {
                self.needsAuthorization = true
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
