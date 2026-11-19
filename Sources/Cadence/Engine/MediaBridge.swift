import AppKit
import AVFoundation
import CadenceCore
import MediaPlayer

/// Media across the Mac and a connected iPhone:
/// - What Music or Spotify is playing here goes to the phone, whose desk controls drive it.
/// - Media remote control (opt-in): while the phone shows its desk display, the Mac's media keys go
///   to the phone instead, with an optional mini-player. Off, or whenever it isn't sure the phone's
///   there, on screen and you're not on a call, the keys are left alone for the Mac.
/// - Optionally, a meeting alert fades out the Mac's music and says which meeting it is.
@MainActor
final class MediaBridge {
    private let state: AppState
    private let hub: CompanionHub
    private let players = MacPlayers()
    private let keys = MediaKeyTap()
    let hud = MediaHUDController()
    private let speech = AVSpeechSynthesizer()
    private var timer: Timer?
    private var last: MacPlayers.Status?
    private var stoppedAt: Date?
    private var sent: CompanionMedia?
    private var fading = false
    /// The phone's playback, for the remote control's pause limit.
    private var phonePlaying = false
    private var phoneStoppedAt: Date?
    /// Presenting or sharing (checked on the poll): the mini-player stays out of the way.
    private var presenting = false

    init(state: AppState, hub: CompanionHub) {
        self.state = state
        self.hub = hub
        hub.macMedia = { [weak self] in self?.current(includeArtwork: true) }
        hub.onPhoneMedia = { [weak self] media in self?.phoneMediaChanged(media) }
        hub.onMediaCommand = { [weak self] command in self?.players.send(command) }
        hub.onPhoneVolume = { [weak self] level, muted in
            self?.hud.model.volume = level
            self?.hud.model.muted = muted
        }
        keys.shouldIntercept = { [weak self] in self?.remoteTakesKeys() ?? false }
        keys.onKey = { [weak self] key in self?.remoteKey(key.command) }
        hud.send = { [weak self] command in self?.sendToPhone(command) }

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
        updateRemote()
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
        let playing = media?.isPlaying == true
        if phonePlaying && !playing { phoneStoppedAt = Date() }
        if playing { phoneStoppedAt = nil }
        phonePlaying = playing
        let model = hud.model
        if let media {
            if let data = media.artwork { model.artwork = NSImage(data: data) }
            else if media.trackID != model.media?.trackID { model.artwork = nil }
            model.media = media
            model.lastApp = media.app
        } else {
            // Stopped: keep showing the last track, paused (the phone only reports what's playing).
            model.media?.isPlaying = false
        }
    }

    // MARK: Media remote control

    /// The input to the remote's rules, minus the call check (that's done live, per key).
    private var gateInput: MediaRemoteGate.Input {
        MediaRemoteGate.Input(enabled: state.prefs.mediaRemoteControl, phoneDisplaying: hub.phoneDisplaying,
                              lastHeard: hub.lastHeard, onCall: false, phonePlaying: phonePlaying,
                              phoneStoppedAt: phoneStoppedAt, pauseLimit: state.prefs.mediaRemotePauseLimit)
    }

    /// Asked for each media key press, so it has to be quick: cheap checks first, the
    /// microphone (on a call?) only when everything else says yes.
    private func remoteTakesKeys() -> Bool {
        guard MediaRemoteGate.intercepts(gateInput, now: Date()) else { return false }
        return SystemContext.microphoneApp() == nil
    }

    private func remoteKey(_ command: MediaCommand) {
        sendToPhone(command)
        guard state.prefs.mediaHUD != .never, !presenting else { return }
        let part: MediaHUDModel.Part = command.isVolume ? .volume
            : command == .next ? .next : command == .previous ? .previous : .playPause
        hud.flash(part)
    }

    /// Sends a key (or a mini-player click) to the phone, and shows the change straight away.
    private func sendToPhone(_ command: MediaCommand) {
        hub.broadcast(.mediaCommand(command))
        let model = hud.model
        switch command {
        case .volumeUp:
            if model.muted { model.muted = false } else if let v = model.volume { model.volume = MediaVolume.stepped(v, up: true) }
        case .volumeDown:
            if !model.muted, let v = model.volume { model.volume = MediaVolume.stepped(v, up: false) }
        case .toggleMute:
            model.muted.toggle()
        case .togglePlayPause:
            model.media?.isPlaying.toggle()
        default:
            break
        }
    }

    /// On the poll: the key tap on or off, and the always-on mini-player.
    private func updateRemote() {
        let prefs = state.prefs
        // Only tap the keys while a phone's connected: otherwise nothing's in their way at all.
        keys.update(wanted: prefs.mediaRemoteControl && hub.isConnected)
        let model = hud.model
        guard hub.isConnected else {
            phonePlaying = false
            phoneStoppedAt = nil
            model.media = nil
            model.artwork = nil
            model.volume = nil
            hud.hide()
            return
        }
        model.phoneName = hub.phones.first?.name ?? "iPhone"
        let ready = MediaRemoteGate.phoneReady(gateInput, now: Date())
        guard prefs.mediaRemoteControl, prefs.mediaHUD != .never, ready || hud.isVisible else {
            if hud.isVisible { hud.hide() }
            return
        }
        // Out of the way while presenting, sharing or on a call.
        let context = SystemContext.current()
        presenting = !context.presenting.isEmpty
        let busy = presenting || context.microphoneApp != nil
        if !ready || busy {
            hud.hide()
        } else if prefs.mediaHUD == .always {
            hud.pin()
        } else if hud.pinned {
            hud.unpin(hide: true)
        }
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
        case .volumeUp, .volumeDown, .toggleMute: return // the Mac's own keys already do this
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
