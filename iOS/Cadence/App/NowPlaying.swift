import AVFoundation
import CadenceCore
import MediaPlayer
import Observation
import UIKit

/// What's playing on this phone. The system Music player (Apple Music and the library) can be read
/// and controlled; Spotify and the rest don't share now-playing details with other apps, so for
/// those we only know *that* something is playing (and can stop it, as the meeting hand-off does).
@MainActor
@Observable
final class NowPlaying {
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var artwork: UIImage?
    private(set) var trackID: String?
    /// The Music app is playing.
    private(set) var musicPlaying = false
    /// Some other app (Spotify, a podcast…) is playing.
    private(set) var otherPlaying = false
    private(set) var authorized = NowPlaying.libraryStatus == .authorized

    /// Set once Cadence has asked for Music access. Until then the status isn't read at all: on
    /// recent iOS even reading `MPMediaLibrary.authorizationStatus()` shows the prompt, and that
    /// should wait for something the user does (tapping the Music button, picking Apple Music).
    private static let askedKey = "Cadence.music.asked"
    private static var libraryStatus: MPMediaLibraryAuthorizationStatus {
        UserDefaults.standard.bool(forKey: askedKey) ? MPMediaLibrary.authorizationStatus() : .notDetermined
    }

    /// Fetched on use, not up front: touching the system player is enough for iOS to show the
    /// Music permission prompt, which should wait for something the user does.
    private var player: MPMusicPlayerController { .systemMusicPlayer }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    /// When playback last stopped, so a pause by hand doesn't make the controls vanish under your finger.
    private(set) var stoppedAt: Date?

    var isPlaying: Bool { musicPlaying || otherPlaying }
    var hasTrack: Bool { title != nil }

    /// Show the controls: playing, or stopped in the last few seconds.
    func showsControls(now: Date) -> Bool {
        isPlaying || (stoppedAt.map { now.timeIntervalSince($0) < 12 } ?? false)
    }

    /// Called every second while the desk display is up: other apps' audio has no notification.
    func poll() {
        if started, (player.playbackState == .playing) != musicPlaying { update() }
        // The Music app counts as "other audio" too, so only look past it.
        let other = AVAudioSession.sharedInstance().isOtherAudioPlaying && !musicPlaying
        if other != otherPlaying {
            if otherPlaying && !other { stoppedAt = Date() }
            otherPlaying = other
        }
    }

    /// Media library access hasn't been asked for yet.
    var canPrompt: Bool { Self.libraryStatus == .notDetermined }

    /// Asks for media library access the first time (needed to read the track), then starts watching.
    /// `answered` runs once the prompt is answered (only when it was shown).
    func start(prompt: Bool = true, answered: (@MainActor () -> Void)? = nil) {
        guard !started else { return }
        switch Self.libraryStatus {
        case .authorized:
            begin()
        case .notDetermined where prompt:
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            MPMediaLibrary.requestAuthorization { status in
                Task { @MainActor [weak self] in
                    self?.authorized = status == .authorized
                    if status == .authorized { self?.begin() }
                    answered?()
                }
            }
        default:
            authorized = false
        }
    }

    private func begin() {
        guard !started else { return }
        started = true
        authorized = true
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     .MPMusicPlayerControllerPlaybackStateDidChange,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        update()
    }

    private func update() {
        let item = player.nowPlayingItem
        title = item?.title
        trackID = item.map { String($0.persistentID) }
        artist = item?.artist ?? item?.albumTitle
        artwork = item?.artwork?.image(at: CGSize(width: 160, height: 160))
        let playing = player.playbackState == .playing
        if musicPlaying && !playing { stoppedAt = Date() }
        musicPlaying = playing
        if playing { otherPlaying = false }
    }

    func pauseMusic() {
        player.pause()
        if musicPlaying { stoppedAt = Date() }
        musicPlaying = false
    }

    func resumeMusic() {
        player.play()
        musicPlaying = true
    }

    /// Forget the grace period (the meeting hand-off stopped it: no need to hang about).
    func clearRecent() { stoppedAt = nil }

    func next() { player.skipToNextItem() }

    /// What to tell the Mac: the Music app's track, or just that another app (assumed to be the
    /// preferred one) is playing.
    func companionMedia(preferred: MediaApp, includeArtwork: Bool) -> CompanionMedia? {
        if musicPlaying {
            return CompanionMedia(app: .appleMusic, title: title, artist: artist, isPlaying: true,
                                  artwork: includeArtwork ? artwork?.jpegData(compressionQuality: 0.7) : nil,
                                  trackID: trackID, canSkip: true)
        }
        if otherPlaying { return CompanionMedia(app: preferred, isPlaying: true, trackID: "other-\(preferred.rawValue)") }
        return nil
    }

    /// Back to the start of the track, or the previous one if it's only just started (like Music).
    func previous() {
        if player.currentPlaybackTime > 3 { player.skipToBeginning() } else { player.skipToPreviousItem() }
    }

    /// Stops the Music app outright, so it doesn't come back when Cadence lets go of the audio.
    func pauseForMeeting() -> Bool {
        guard started, player.playbackState == .playing else { return false }
        pauseMusic()
        clearRecent()
        return true
    }
}

/// When a meeting alert comes up while something's playing through this phone: fade the music
/// out, say which meeting it is, then let go of the audio entirely so the headphones (e.g. AirPods
/// with automatic switching) are free to move to the Mac for the call.
@MainActor
final class MeetingAudioHandoff: NSObject, AVSpeechSynthesizerDelegate {
    private let session = AVAudioSession.sharedInstance()
    private let synth = AVSpeechSynthesizer()
    private var running = false
    private var finish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Whether any audio (this phone's Music app, Spotify, a podcast…) is playing right now.
    var otherAudioPlaying: Bool { session.isOtherAudioPlaying }

    /// Fades out whatever's playing, announces `meeting`, then releases the audio session.
    /// `force` runs it even with nothing playing (the Settings test button).
    func run(for meeting: Meeting, now: Date, nowPlaying: NowPlaying, spotify: SpotifyRemote, announce: Bool, force: Bool = false) {
        guard !running, force || session.isOtherAudioPlaying else { return }
        running = true
        do {
            // 1. Duck: iOS ramps the other app's volume down for us — the quick fade.
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            running = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            // 2. Stop it. Music is paused directly; anything else (Spotify, podcasts) is interrupted
            // by switching to audio that doesn't mix, and isn't told to resume when we let go.
            _ = nowPlaying.pauseForMeeting()
            _ = spotify.pauseForMeeting()
            try? self.session.setCategory(.playback, mode: .spokenAudio, options: [])
            try? self.session.setActive(true)
            // 3. Say what it is, then 4. let go.
            if announce {
                self.finish = { [weak self] in self?.release() }
                self.synth.speak(Self.utterance(for: meeting, now: now))
            } else {
                self.release()
            }
        }
    }

    /// Stops another app's audio (Spotify etc.): grab audio that doesn't mix, then let go without
    /// telling it to resume. There's no way to start it again from here; that's done in the app.
    func interruptOthers() {
        guard !running else { return }
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            try session.setActive(false)
        } catch {}
    }

    private func release() {
        finish = nil
        // A beat after the voice so the last word isn't clipped. No .notifyOthersOnDeactivation:
        // the music stays stopped and the headphones go quiet, which is what lets them switch over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            try? self.session.setActive(false)
            self.running = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish?() }
    }

    static func phrase(for meeting: Meeting, now: Date) -> String {
        let seconds = meeting.start.timeIntervalSince(now)
        let when: String
        if seconds <= 10 && seconds >= -60 { when = "is starting now" }
        else if seconds < -60 { when = "started \(Int(-seconds / 60)) minute\(Int(-seconds / 60) == 1 ? "" : "s") ago" }
        else if seconds < 90 { when = "starts in \(max(1, Int(seconds.rounded())) ) seconds" }
        else { when = "starts in \(Int((seconds / 60).rounded())) minutes" }
        return "Heads up. \(meeting.title) \(when)."
    }

    private static func utterance(for meeting: Meeting, now: Date) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: phrase(for: meeting, now: now))
        u.voice = bestVoice()
        u.prefersAssistiveTechnologySettings = true
        return u
    }

    /// Siri's own voices aren't open to other apps, so use the best one installed for the phone's
    /// language: Premium, then Enhanced (download them in Settings → Accessibility → Spoken Content).
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.first { $0.quality == .premium } ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }
}
