import AppKit
import AVFoundation
import CadenceCore
import MediaPlayer

/// Media across the Mac and a connected iPhone, with no new UI on the Mac:
/// - What Music or Spotify is playing here goes to the phone, whose desk controls drive it.
/// - What the phone is playing takes over the Mac's own Now Playing (Control Center, media keys),
///   so the keyboard's play/pause/skip control the phone.
/// - Optionally, a meeting alert fades out the Mac's music and says which meeting it is.
@MainActor
final class MediaBridge {
    private let state: AppState
    private let hub: CompanionHub
    private let players = MacPlayers()
    private let phoneNowPlaying = PhoneNowPlaying()
    private let speech = AVSpeechSynthesizer()
    private var timer: Timer?
    private var last: MacPlayers.Status?
    private var stoppedAt: Date?
    private var sent: CompanionMedia?
    private var fading = false

    init(state: AppState, hub: CompanionHub) {
        self.state = state
        self.hub = hub
        hub.macMedia = { [weak self] in self?.current(includeArtwork: true) }
        hub.onPhoneMedia = { [weak self] media in self?.phoneMediaChanged(media) }
        hub.onMediaCommand = { [weak self] command in self?.players.send(command) }
        phoneNowPlaying.send = { [weak hub] command in hub?.broadcast(.mediaCommand(command)) }

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var sharing: Bool { state.prefs.shareMediaWithPhone }

    // MARK: Mac → phone

    /// Only asks the players while there's someone to tell (AppleScript isn't free).
    private func poll() {
        guard sharing, hub.isConnected, !fading else {
            if !hub.isConnected { sent = nil; last = nil }
            return
        }
        let status = players.status()
        if let last, last.isPlaying, status?.isPlaying != true { stoppedAt = Date() }
        if status?.isPlaying == true { stoppedAt = nil }
        last = status
        let media = current(includeArtwork: false)
        guard media != sent else { return }
        let newTrack = media?.trackID != sent?.trackID
        sent = media
        hub.broadcast(.media(newTrack ? current(includeArtwork: true) : media))
    }

    /// Playing, or paused in the last few seconds (so a pause from the phone doesn't make its
    /// controls vanish under your finger).
    private func current(includeArtwork: Bool) -> CompanionMedia? {
        guard sharing, let s = last else { return nil }
        guard s.isPlaying || stoppedAt.map({ Date().timeIntervalSince($0) < 12 }) == true else { return nil }
        return CompanionMedia(app: s.app, title: s.title, artist: s.artist, isPlaying: s.isPlaying,
                              artwork: includeArtwork ? players.artwork(for: s) : nil,
                              trackID: s.trackID, canSkip: true)
    }

    // MARK: Phone → Mac

    private func phoneMediaChanged(_ media: CompanionMedia?) {
        guard sharing else { return phoneNowPlaying.update(nil) }
        phoneNowPlaying.update(media)
    }

    // MARK: Meeting alerts

    /// Fade out whatever's playing on the Mac, then say which meeting it is. Only when something is.
    func meetingAlert(_ meeting: Meeting) {
        guard state.prefs.fadeMediaForAlerts, !fading, let status = players.status(), status.isPlaying else { return }
        fading = true
        Task { @MainActor in
            await players.fadeOutAndPause(status.app)
            fading = false
            stoppedAt = nil
            last = nil
            poll()
            guard state.prefs.announceAlerts else { return }
            let u = AVSpeechUtterance(string: MediaBridge.phrase(for: meeting, now: Date()))
            // Follows Accessibility → Spoken Content (system voice, rate).
            u.prefersAssistiveTechnologySettings = true
            speech.speak(u)
        }
    }

    /// Settings → Test: the fade and announcement on a demo meeting.
    func test() {
        let m = Meeting(id: "preview-audio", title: "Design Review",
                        start: Date().addingTimeInterval(60), end: Date().addingTimeInterval(1860),
                        calendar: CalendarInfo(id: "preview", title: "Work", sourceTitle: "Preview", color: RGBAColor(red: 0.35, green: 0.45, blue: 1)))
        if players.status()?.isPlaying == true {
            let fade = state.prefs.fadeMediaForAlerts
            state.prefs.fadeMediaForAlerts = true
            meetingAlert(m)
            state.prefs.fadeMediaForAlerts = fade
        } else {
            let u = AVSpeechUtterance(string: MediaBridge.phrase(for: m, now: Date()))
            u.prefersAssistiveTechnologySettings = true
            speech.speak(u)
        }
    }

    static func phrase(for meeting: Meeting, now: Date) -> String {
        let seconds = meeting.start.timeIntervalSince(now)
        let when: String
        if seconds <= 10 && seconds >= -60 { when = "is starting now" }
        else if seconds < -60 { let m = Int(-seconds / 60); when = "started \(m) minute\(m == 1 ? "" : "s") ago" }
        else if seconds < 90 { when = "starts in \(Int(seconds.rounded())) seconds" }
        else { when = "starts in \(Int((seconds / 60).rounded())) minutes" }
        return "Heads up. \(meeting.title) \(when)."
    }
}

// MARK: - Music & Spotify on this Mac

/// Reads and drives Music and Spotify through AppleScript. Never launches them: an app that isn't
/// running is skipped (asking it anything would open it).
@MainActor
final class MacPlayers {
    struct Status: Equatable {
        var app: MediaApp
        var title: String?
        var artist: String?
        var trackID: String?
        var isPlaying: Bool
        var artworkURL: String?
    }

    private static let bundleIDs: [MediaApp: String] = [.appleMusic: "com.apple.Music", .spotify: "com.spotify.client"]
    private var artworkCache: (trackID: String, data: Data?)?

    private func scriptName(_ app: MediaApp) -> String { app == .spotify ? "Spotify" : "Music" }

    private func isRunning(_ app: MediaApp) -> Bool {
        guard let id = Self.bundleIDs[app] else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Cadence: media script failed: \(error)") }
        return result
    }

    /// The player that's playing, else one that's paused with a track; nil if neither is open.
    func status() -> Status? {
        let found = [MediaApp.appleMusic, .spotify].filter(isRunning).compactMap(read)
        return found.first(where: \.isPlaying) ?? found.first
    }

    private func read(_ app: MediaApp) -> Status? {
        let idProp = app == .spotify ? "id" : "persistent ID"
        let art = app == .spotify ? " & tab & (artwork url of t)" : ""
        let source = """
        tell application "\(scriptName(app))"
            if player state is stopped then return "stopped"
            try
                set t to current track
                return (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (\(idProp) of t)\(art)
            on error
                return (player state as text)
            end try
        end tell
        """
        guard let text = run(source)?.stringValue, text != "stopped" else { return nil }
        let parts = text.components(separatedBy: "\t")
        func part(_ i: Int) -> String? { parts.indices.contains(i) && !parts[i].isEmpty ? parts[i] : nil }
        return Status(app: app, title: part(1), artist: part(2), trackID: part(3).map { "\(app.rawValue)-\($0)" },
                      isPlaying: parts[0] == "playing", artworkURL: part(4))
    }

    /// Small JPEG of the track's artwork, fetched once per track.
    func artwork(for status: Status) -> Data? {
        guard let id = status.trackID else { return nil }
        if let cache = artworkCache, cache.trackID == id { return cache.data }
        var raw: Data?
        if status.app == .appleMusic {
            raw = run("tell application \"Music\" to get raw data of artwork 1 of current track")?.data
        } else if let s = status.artworkURL, let url = URL(string: s) {
            raw = try? Data(contentsOf: url) // small, and only on a track change
        }
        let data = raw.flatMap(Self.thumbnail)
        artworkCache = (id, data)
        return data
    }

    private static func thumbnail(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = NSSize(width: 160, height: 160)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        guard let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// From the phone's controls: aimed at whichever player is playing (or was last).
    func send(_ command: MediaCommand) {
        guard let app = status()?.app else { return }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        run("tell application \"\(scriptName(app))\" to \(verb)")
    }

    /// A quick ramp to silence, pause, then put the volume back for next time.
    func fadeOutAndPause(_ app: MediaApp) async {
        let name = scriptName(app)
        guard let start = run("tell application \"\(name)\" to get sound volume")?.int32Value, start > 0 else {
            run("tell application \"\(name)\" to pause")
            return
        }
        let steps = 10
        for i in 1...steps {
            let v = Int(Double(start) * (1 - Double(i) / Double(steps)))
            run("tell application \"\(name)\" to set sound volume to \(v)")
            try? await Task.sleep(nanoseconds: 70_000_000)
        }
        run("tell application \"\(name)\" to pause")
        try? await Task.sleep(nanoseconds: 150_000_000)
        run("tell application \"\(name)\" to set sound volume to \(start)")
    }
}

// MARK: - The phone's music in the Mac's Now Playing

/// While the phone is playing, Cadence stands in as the Mac's Now Playing app: Control Center
/// shows the phone's track and the media keys go to the phone. Lets go as soon as it stops.
@MainActor
final class PhoneNowPlaying {
    var send: ((MediaCommand) -> Void)?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artwork: NSImage?
    private var trackID: String?

    func update(_ media: CompanionMedia?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let media else {
            if !targets.isEmpty {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
                removeTargets()
            }
            artwork = nil
            trackID = nil
            return
        }
        if let data = media.artwork { artwork = NSImage(data: data) } else if media.trackID != trackID { artwork = nil }
        trackID = media.trackID
        if targets.isEmpty { addTargets() }
        let rc = MPRemoteCommandCenter.shared()
        rc.nextTrackCommand.isEnabled = media.canSkip
        rc.previousTrackCommand.isEnabled = media.canSkip

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: media.title ?? "Playing on iPhone",
            MPMediaItemPropertyArtist: media.title == nil ? media.app.name : (media.artist ?? media.app.name),
            MPNowPlayingInfoPropertyPlaybackRate: media.isPlaying ? 1.0 : 0.0,
        ]
        if let image = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        center.playbackState = media.isPlaying ? .playing : .paused
    }

    private func addTargets() {
        let rc = MPRemoteCommandCenter.shared()
        let pairs: [(MPRemoteCommand, MediaCommand)] = [
            (rc.playCommand, .play), (rc.pauseCommand, .pause), (rc.togglePlayPauseCommand, .togglePlayPause),
            (rc.nextTrackCommand, .next), (rc.previousTrackCommand, .previous),
        ]
        for (command, action) in pairs {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in self?.send?(action) }
                return .success
            }
            targets.append((command, token))
        }
    }

    private func removeTargets() {
        for (command, token) in targets {
            command.removeTarget(token)
            command.isEnabled = false
        }
        targets = []
    }
}
