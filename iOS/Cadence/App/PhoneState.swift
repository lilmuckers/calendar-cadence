import CadenceCore
import Foundation
import Observation
import UIKit

/// Root model on the iPhone. Standalone it reads its own calendars (iPhone Calendar, Google,
/// Microsoft, ICS) and runs its own alerts; connected to the Mac it mirrors the Mac's meetings and
/// shows the Mac's alerts instead, so nothing fires twice.
@MainActor
@Observable
final class PhoneState {
    static let shared = PhoneState()

    var prefs: PhonePrefs {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            if prefs.icsFeeds != oldValue.icsFeeds { syncFeeds(fetch: true) }
            if prefs.filters != oldValue.filters { recompute() }
            scheduleBackgroundWork()
        }
    }

    private(set) var now = Date()
    private(set) var calendars: [CalendarInfo] = []
    /// This phone's own merged, filtered meetings.
    private(set) var ownMeetings: [Meeting] = []
    /// The Mac's last snapshot (kept after disconnecting, shown when there's nothing else).
    private(set) var snapshot: CompanionSnapshot? = PhoneState.loadSnapshot()
    private(set) var calendarAccess: Bool = false
    private(set) var lastRefresh: Date?

    /// The full-screen alert being shown, if any.
    var alerting: Meeting?
    /// A reminder from the Mac, shown as an in-app banner.
    var banner: CompanionReminder?
    /// Pop-ups from the Mac waiting for a decision, oldest first. Only while connected: the Mac
    /// shows whatever's left itself once the link drops.
    private(set) var invitePrompts: [CompanionInvite] = []
    private(set) var clashPrompts: [CompanionClash] = []

    let link = CompanionClient()
    let desk = DeskMode()
    let nowPlaying = NowPlaying()
    let spotify = SpotifyRemote()
    /// What the Mac is playing (Music or Spotify there), while connected.
    private(set) var macMedia: CompanionMedia?
    private(set) var macArtwork: UIImage?
    @ObservationIgnored private var sentMedia: CompanionMedia?
    @ObservationIgnored let audioHandoff = MeetingAudioHandoff()
    @ObservationIgnored let notifier = PhoneNotifier()
    @ObservationIgnored let liveActivity = LiveActivityController()

    let googleAuth = GoogleAuth()
    let microsoftAuth = MicrosoftAuth()
    @ObservationIgnored private let eventKit = EventKitProvider()
    private(set) var googleProviders: [GoogleCalendarProvider] = []
    private(set) var microsoftProviders: [MicrosoftCalendarProvider] = []
    private(set) var icsProviders: [ICSProvider] = []
    @ObservationIgnored private var providers: [CalendarProvider] { [eventKit] + googleProviders + microsoftProviders + icsProviders }

    @ObservationIgnored private var planner = AlertPlanner()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastRemoteRefresh: Date?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var started = false

    private init() {
        prefs = PhonePrefs.load()
    }

    // MARK: - Source of truth

    /// Connected: the Mac's meetings. Otherwise the Mac's last copy merged with any calendars on this
    /// phone, so the agenda, alerts and notifications carry on without the Mac.
    var meetings: [Meeting] {
        if link.isConnected, let snapshot { return snapshot.meetings }
        return offlineMeetings
    }

    /// The Mac's last snapshot plus this phone's own meetings, duplicates merged.
    private var offlineMeetings: [Meeting] {
        guard let cached = macCopy, !cached.isEmpty else { return ownMeetings }
        guard !ownMeetings.isEmpty else { return cached }
        return MeetingDeduplicator.dedupe((cached + ownMeetings).sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) })
    }

    /// The cached Mac meetings, while paired (unpairing drops them).
    private var macCopy: [Meeting]? { link.mac == nil ? nil : snapshot?.meetings }

    var usingMac: Bool { link.isConnected && snapshot != nil }
    /// Showing the Mac's saved agenda while it's out of reach.
    var usingMacCopy: Bool { !link.isConnected && !(macCopy ?? []).isEmpty }
    /// When the saved agenda was last brought up to date.
    var macCopyDate: Date? { snapshot?.generatedAt }
    var hasOwnSources: Bool { calendarAccess || !googleProviders.isEmpty || !microsoftProviders.isEmpty || !icsProviders.isEmpty }
    /// Meetings muted by a clash choice or an agenda-only calendar on the Mac (still honoured from the
    /// saved copy), plus this phone's own agenda-only calendars.
    private var suppressed: Set<String> {
        (link.mac == nil ? [] : snapshot?.suppressedIDs ?? []).union(ownAgendaOnlyIDs)
    }
    /// Ids in `ownMeetings` that come only from this phone's agenda-only calendars.
    private var ownAgendaOnlyIDs: Set<String> = []

    var todayMeetings: [Meeting] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return meetings.filter { !$0.isAllDay && $0.end > start && $0.start < end }
    }

    var current: [Meeting] { meetings.filter { !$0.isAllDay && $0.isInProgress(at: now) && !isAgendaOnly($0) } }
    var next: Meeting? { meetings.first { !$0.isAllDay && $0.start > now && !isAgendaOnly($0) } }

    /// On an agenda-only calendar (here or on the Mac): shown, but never alerts.
    func isAgendaOnly(_ m: Meeting) -> Bool {
        ownAgendaOnlyIDs.contains(m.id) || (link.mac != nil && snapshot?.agendaOnlyIDs?.contains(m.id) == true)
    }

    /// What the desk display focuses on: the next meeting, or the live one when nothing's close.
    var focus: PanelFocus? {
        PanelPlanner.focus(meetings: meetings, now: now, isHidden: { [suppressed] in suppressed.contains($0.id) },
                           withinMinutes: 0, showDuringMeetings: true)
    }

    /// The rest of today after the focused meeting.
    var laterToday: [Meeting] {
        todayMeetings.filter { $0.end > now && $0.id != focus?.meeting.id && !($0.isInProgress(at: now) && focus?.live == false) }
    }

    /// Whether this phone counts as "displaying" for the Mac: on screen, in desk mode.
    var displaying: Bool { isActive && desk.isOn }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-previewPrompts") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.loadPreviewPrompts() }
        }
        // -previewMedia spotify: pretend the Mac is playing, to see the desk's media card.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-previewMedia") {
            let app = args.indices.contains(i + 1) ? MediaApp(rawValue: args[i + 1]) ?? .appleMusic : .appleMusic
            // "-previewMedia launcher": nothing playing, so the corner shows the open-app button.
            if args.indices.contains(i + 1), let preferred = MediaApp(rawValue: args[i + 1]), args.contains("-launcher") {
                prefs.mediaApp = preferred
            } else {
                macMedia = CompanionMedia(app: app, title: "Midnight Drive", artist: "The Night Shift", isPlaying: true, canSkip: true)
            }
            desk.set(true)
        }
        #endif
        eventKit.onChange = { [weak self] in self?.refresh() }
        link.onMessage = { [weak self] in self?.handle($0) }
        link.onDisconnected = { [weak self] in
            self?.macMedia = nil
            self?.sentMedia = nil
            self?.invitePrompts = []
            self?.clashPrompts = []
        }
        desk.onChange = { [weak self] in self?.displayChanged() }
        notifier.onJoin = { [weak self] id in self?.join(id: id) }
        notifier.isForegroundSuppressed = { [weak self] in
            // On screen we show our own overlay, and the Mac's reminders arrive over the link.
            guard let self else { return false }
            return self.isActive
        }
        notifier.setUp()
        syncGoogle(fetch: false)
        syncMicrosoft(fetch: false)
        syncFeeds(fetch: false)
        calendarAccess = eventKit.isAuthorized
        refresh()
        Task { await refreshRemote() }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func requestCalendarAccess() async {
        calendarAccess = await eventKit.requestAccess()
        refresh()
    }

    var calendarAccessDenied: Bool { eventKit.isDenied }

    /// Scene became active / inactive.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            spotify.resume()
            link.start()
            refresh()
            if let last = lastRemoteRefresh, Date().timeIntervalSince(last) > 300 { Task { await refreshRemote() } }
        } else {
            spotify.suspend()
            link.stop()
            scheduleBackgroundWork()
            // Last chance to start a Live Activity until the app is opened again.
            updateLiveActivity(leaving: true)
        }
        displayChanged()
    }

    private func displayChanged() {
        link.displaying = displaying
        UIApplication.shared.isIdleTimerDisabled = displaying
    }

    // MARK: - Data

    func refresh() {
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.date(byAdding: .day, value: 2, to: from) ?? from.addingTimeInterval(172_800)
        calendars = providers.flatMap { $0.calendars() }
        let all = providers.flatMap { $0.meetings(from: from, to: to) }
            .sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
        rawMeetings = all
        lastRefresh = Date()
        recompute()
    }

    @ObservationIgnored private var rawMeetings: [Meeting] = []

    private func recompute() {
        let shown = rawMeetings.filter { prefs.filters.allows($0) }
        let merged = MeetingDeduplicator.dedupe(shown)
        ownAgendaOnlyIDs = prefs.filters.agendaOnlyIDs(in: merged, sources: shown)
        ownMeetings = merged
        planner.prune(keeping: meetings)
        updateLiveActivity()
    }

    func refreshRemote() async {
        lastRemoteRefresh = Date()
        await withTaskGroup(of: Void.self) { group in
            for provider in providers { group.addTask { await provider.refreshRemote() } }
        }
        refresh()
        scheduleBackgroundWork()
    }

    func isCalendarEnabled(_ id: String) -> Bool { !prefs.filters.disabledCalendarIDs.contains(id) }

    func isCalendarAgendaOnly(_ id: String) -> Bool { prefs.filters.agendaOnlyCalendarIDs.contains(id) }

    func setCalendar(_ id: String, agendaOnly: Bool) {
        if agendaOnly { prefs.filters.agendaOnlyCalendarIDs.insert(id) } else { prefs.filters.agendaOnlyCalendarIDs.remove(id) }
    }

    func setCalendar(_ id: String, enabled: Bool) {
        if enabled { prefs.filters.disabledCalendarIDs.remove(id) } else { prefs.filters.disabledCalendarIDs.insert(id) }
    }

    // MARK: - Mac link

    private func handle(_ message: CompanionMessage) {
        switch message {
        case .welcome:
            break // the Mac decides alerts while connected; the planner keeps what's fired for later
        case .snapshot(let snap):
            snapshot = snap
            Self.saveSnapshot(snap)
            planner.prune(keeping: snap.meetings + ownMeetings)
            updateLiveActivity()
        case .alert(let meeting):
            // Remembered, so it doesn't fire a second time if the link drops before the meeting starts.
            planner.markFired(meeting)
            present(meeting)
        case .dismissAlert(let id):
            if alerting?.id == id { alerting = nil }
        case .invitePrompt(let invites):
            let fresh = invites.filter { i in !invitePrompts.contains { $0.meeting.id == i.meeting.id } }
            guard !fresh.isEmpty else { break }
            invitePrompts += fresh
            haptic(.success)
        case .inviteHandled(let id):
            invitePrompts.removeAll { $0.meeting.id == id }
        case .clashPrompt(let clash):
            guard !clashPrompts.contains(where: { $0.key == clash.key }) else { break }
            clashPrompts.append(clash)
            haptic(.warning)
        case .clashHandled(let key):
            clashPrompts.removeAll { $0.key == key }
        case .media(let media):
            if let art = media?.artwork { macArtwork = UIImage(data: art) }
            else if media?.trackID != macMedia?.trackID { macArtwork = nil }
            macMedia = media
        case .mediaCommand(let command):
            applyMediaCommand(command)
        case .reminder(let reminder):
            banner = reminder
            haptic(.warning)
            let key = reminder.key
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                if self?.banner?.key == key { self?.banner = nil }
            }
        default:
            break
        }
    }

    private static let snapshotKey = "Cadence.companion.snapshot"

    private static func loadSnapshot() -> CompanionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(CompanionSnapshot.self, from: data)
    }

    private static func saveSnapshot(_ snap: CompanionSnapshot) {
        if let data = try? JSONEncoder().encode(snap) { UserDefaults.standard.set(data, forKey: snapshotKey) }
    }

    // MARK: - Tick & alerts

    private func tick() {
        now = Date()
        if let last = lastRefresh, now.timeIntervalSince(last) > 300 { refresh() }
        if isActive, let last = lastRemoteRefresh, now.timeIntervalSince(last) > 600 { Task { await refreshRemote() } }
        // Connected: the Mac sends alerts. Standalone: plan our own.
        if !link.isConnected { checkAlert() }
        // Previews stay up until dismissed, so a short auto-close can't cut the meltdown preview off.
        if let alerting, !alerting.id.hasPrefix("preview"), let closeAt = autoDismissDate(for: alerting), now > closeAt {
            self.alerting = nil
        }
        if Int(now.timeIntervalSince1970) % 30 == 0 { updateLiveActivity() }
        if isActive && (displaying || link.isConnected) {
            nowPlaying.poll()
            // Something's playing that isn't Music: if it's Spotify, pick up its track quietly.
            if nowPlaying.otherPlaying && prefs.mediaApp == .spotify { spotify.connectIfPossible() }
        }
        syncMediaToMac()
    }

    /// Tells the Mac when what's playing here changes, so its media keys and Now Playing follow.
    private func syncMediaToMac() {
        guard link.isConnected else { sentMedia = nil; return }
        let current = phoneMedia(includeArtwork: false)
        guard current != sentMedia else { return }
        let newTrack = current?.trackID != sentMedia?.trackID
        sentMedia = current
        link.send(.media(newTrack ? phoneMedia(includeArtwork: true) : current))
    }

    private func phoneMedia(includeArtwork: Bool) -> CompanionMedia? {
        if !nowPlaying.musicPlaying, let s = spotify.companionMedia(includeArtwork: includeArtwork) { return s }
        return nowPlaying.companionMedia(preferred: prefs.mediaApp, includeArtwork: includeArtwork)
    }

    /// Mac media keys / Control Center (via the Mac), aimed at what's playing on this phone.
    private func applyMediaCommand(_ command: MediaCommand) {
        let np = nowPlaying
        if spotify.connected && !np.musicPlaying && (spotify.isPlaying || !np.hasTrack) {
            switch command {
            case .play: spotify.play()
            case .pause: spotify.pause()
            case .togglePlayPause: spotify.togglePlay()
            case .next: spotify.next()
            case .previous: spotify.previous()
            }
            return
        }
        switch command {
        case .play: if np.hasTrack { np.resumeMusic() }
        case .pause: pauseMedia()
        case .togglePlayPause:
            if np.isPlaying { pauseMedia() } else if np.hasTrack { np.resumeMusic() }
        case .next: np.next()
        case .previous: np.previous()
        }
    }

    /// Desk controls aimed at the Mac's player.
    func controlMac(_ command: MediaCommand) {
        link.send(.mediaCommand(command))
        if var m = macMedia, command == .togglePlayPause || command == .play || command == .pause {
            m.isPlaying = command == .togglePlayPause ? !m.isPlaying : command == .play
            macMedia = m
        }
    }

    /// When an ignored alert closes itself: the auto-dismiss minutes after the start (the Mac's while
    /// connected), but never past the meeting's end. Nil = stays until acted on.
    private func autoDismissDate(for meeting: Meeting) -> Date? {
        let minutes = link.isConnected ? snapshot?.takeoverAutoDismissMinutes ?? prefs.takeoverAutoDismissMinutes
                                       : prefs.takeoverAutoDismissMinutes
        guard minutes > 0 else { return nil }
        return min(meeting.start.addingTimeInterval(TimeInterval(minutes) * 60), max(meeting.end, meeting.start))
    }

    private func checkAlert() {
        guard prefs.takeoverEnabled else { return }
        let candidates = offlineMeetings.filter {
            !suppressed.contains($0.id) && (!prefs.takeoverOnlyWithLink || $0.joinLink != nil)
        }
        guard let due = planner.due(in: candidates, now: now, leadTime: prefs.takeoverLeadSeconds) else { return }
        planner.markFired(due)
        if isActive { present(due) }
    }

    private func present(_ meeting: Meeting) {
        alerting = meeting
        haptic(.warning)
        // Music through this phone: fade it, say what's on, and free the headphones for the Mac.
        // The voice stands in for the chime then. Audio can only be taken while Cadence is on screen.
        if isActive && prefs.pauseMediaForAlerts && audioHandoff.otherAudioPlaying {
            audioHandoff.run(for: meeting, now: now, nowPlaying: nowPlaying, spotify: spotify, announce: prefs.announceAlerts)
        } else if prefs.alertSound {
            AlertSound.play()
        }
    }

    /// Settings → Media → Test: the hand-off on a demo meeting, even with nothing playing.
    func testAudioHandoff() {
        let m = Meeting(
            id: "preview-audio", title: "Design Review",
            start: Date().addingTimeInterval(60), end: Date().addingTimeInterval(1860),
            calendar: CalendarInfo(id: "preview", title: "Work", sourceTitle: "Preview", color: RGBAColor(red: 0.35, green: 0.45, blue: 1)))
        audioHandoff.run(for: m, now: Date(), nowPlaying: nowPlaying, spotify: spotify, announce: true, force: true)
    }

    /// Desk media button: open the preferred player.
    func openMediaApp() {
        UIApplication.shared.open(prefs.mediaApp.url)
    }

    /// The desk's idle media button. For Spotify it also hooks Cadence up: one tap opens Spotify,
    /// approves (first time), starts your last track and comes back with the controls showing.
    func launchMedia() {
        if prefs.mediaApp == .spotify && spotify.isAvailable {
            if spotify.connected { spotify.play() } else { spotify.authorize() }
        } else {
            openMediaApp()
        }
    }

    /// Pause from the desk controls: Music or Spotify directly, anything else by taking the audio.
    func pauseMedia() {
        if nowPlaying.musicPlaying { nowPlaying.pauseMusic() }
        else if spotify.connected && spotify.isPlaying { spotify.pause() }
        else { audioHandoff.interruptOthers() }
    }

    /// Spotify connected and the one playing (or just paused): it gets the controls.
    var spotifyActive: Bool { spotify.showsControls(now: now) && !nowPlaying.musicPlaying }

    private func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    // MARK: - Actions

    /// Join: on the Mac while connected, otherwise on this phone.
    func join(_ meeting: Meeting) {
        switch JoinDestination.choose(connectedToMac: link.isConnected) {
        case .mac:
            link.send(.join(meetingID: meeting.id))
        case .phone:
            if let url = meeting.joinLink?.url { UIApplication.shared.open(url) }
        }
        if alerting?.id == meeting.id { alerting = nil }
    }

    /// Join by id (from a notification or the Live Activity). Waits briefly for the Mac link to come
    /// back after the app wakes up, then falls back to joining on the phone.
    func join(id: String) {
        Task {
            for _ in 0..<20 where !link.isConnected && link.mac != nil && link.status != .unpaired {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let meeting = meeting(id: id) else { return }
            join(meeting)
        }
    }

    func meeting(id: String) -> Meeting? {
        meetings.first { $0.id == id } ?? ownMeetings.first { $0.id == id } ?? snapshot?.meetings.first { $0.id == id }
    }

    func snooze(_ meeting: Meeting, seconds: TimeInterval = 60) {
        if link.isConnected {
            link.send(.snooze(meetingID: meeting.id, seconds: seconds))
        } else {
            planner.snooze(meeting, until: Date().addingTimeInterval(seconds))
        }
        alerting = nil
    }

    /// Answer an invite pop-up. nil reply = open it in Calendar on the Mac.
    func answer(_ invite: CompanionInvite, _ reply: RSVP?) {
        link.send(.rsvp(meetingID: invite.meeting.id, reply: reply))
        invitePrompts.removeAll { $0.meeting.id == invite.meeting.id }
    }

    /// Close an invite pop-up without answering.
    func later(_ invite: CompanionInvite) {
        link.send(.inviteLater(meetingID: invite.meeting.id))
        invitePrompts.removeAll { $0.meeting.id == invite.meeting.id }
    }

    /// Settle a clash pop-up: a meeting id, "all", or nil for "decide later".
    func resolve(_ clash: CompanionClash, choice: String?) {
        link.send(.resolveClash(key: clash.key, choice: choice))
        clashPrompts.removeAll { $0.key == clash.key }
    }

    #if DEBUG
    /// `-previewPrompts`: sample pop-ups (clash, invite, reminder) in desk mode, for checking the layout.
    func loadPreviewPrompts() {
        func m(_ id: String, _ title: String, _ inMin: Double, _ len: Double, _ c: RGBAColor) -> Meeting {
            let cal = CalendarInfo(id: "preview-\(id)", title: "Work", sourceTitle: "Preview", color: c)
            return Meeting(id: id, title: title, start: Date().addingTimeInterval(inMin * 60),
                           end: Date().addingTimeInterval((inMin + len) * 60), calendar: cal,
                           organizer: "Alex Organiser", attendeeCount: 4, participation: .pending)
        }
        let purple = RGBAColor(red: 0.5, green: 0.47, blue: 0.87)
        let invite = m("p-invite", "Budget review", 85, 30, purple)
        invitePrompts = [CompanionInvite(meeting: invite, canRespond: true)]
        if ProcessInfo.processInfo.arguments.contains("-previewClash") {
            clashPrompts = [CompanionClash(key: "p", meetings: [
                m("p-a", "1:1 with Sam", 40, 30, RGBAColor(red: 0.22, green: 0.54, blue: 0.87)),
                m("p-b", "Vendor call", 55, 30, RGBAColor(red: 0.85, green: 0.35, blue: 0.19)),
            ])]
        }
        desk.set(true)
    }
    #endif

    func dismissAlert() {
        if let alerting, link.isConnected { link.send(.dismiss(meetingID: alerting.id)) }
        alerting = nil
    }

    /// Settings → Alerts → Preview.
    func previewAlert() {
        alerting = next ?? Meeting(
            id: "preview", title: "Design Review",
            start: Date().addingTimeInterval(prefs.takeoverLeadSeconds),
            end: Date().addingTimeInterval(prefs.takeoverLeadSeconds + 1800),
            calendar: CalendarInfo(id: "preview", title: "Work", sourceTitle: "Preview", color: RGBAColor(red: 0.35, green: 0.45, blue: 1)),
            attendeeCount: 6,
            joinLink: MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/123456789")!))
    }

    /// Settings → Alerts → Preview meltdown: a demo meeting that's nearly three minutes late.
    func previewLateAlert(lateBy: TimeInterval = 172) {
        let start = Date().addingTimeInterval(-lateBy)
        alerting = Meeting(
            id: "preview-late", title: "Design Review",
            start: start, end: start.addingTimeInterval(1800),
            calendar: CalendarInfo(id: "preview", title: "Work", sourceTitle: "Preview", color: RGBAColor(red: 0.35, green: 0.45, blue: 1)),
            attendeeCount: 6,
            joinLink: MeetingLink(service: .zoom, url: URL(string: "https://example.com/cadence-preview")!))
    }

    // MARK: - Background

    /// Notifications and the Live Activity keep working while the app is suspended.
    private func scheduleBackgroundWork() {
        notifier.reschedule(meetings: offlineMeetings.filter { !suppressed.contains($0.id) }, prefs: prefs)
        updateLiveActivity()
    }

    /// Live Activity (Lock Screen, StandBy, Dynamic Island): a countdown once the next meeting is within
    /// `liveActivityLeadMinutes`. iOS only lets an app start one while it's open, so when leaving
    /// (`leaving`) one for a later meeting today starts early, showing the start time, and turns into
    /// the countdown by itself at the lead time.
    private func updateLiveActivity(leaving: Bool = false) {
        guard prefs.liveActivityEnabled else { liveActivity.end(); return }
        let now = Date()
        let lead = Double(prefs.liveActivityLeadMinutes) * 60
        guard let f = focus else { liveActivity.end(); return }
        let countdownFrom = f.meeting.start.addingTimeInterval(-lead)
        let early = leaving && Calendar.current.isDate(f.meeting.start, inSameDayAs: now)
            && f.meeting.start.timeIntervalSince(now) < Self.earlyStartLimit
        if f.live || now >= countdownFrom || early {
            let after = laterToday.first { $0.start >= f.meeting.start && $0.id != f.meeting.id }
            // Same as the Mac's menu bar: the mood (and the icon's colour) follow the next meeting to start.
            let moodMeeting = f.live ? after : f.meeting
            liveActivity.show(f.meeting, live: f.live, next: after, onMac: link.isConnected ? link.mac?.displayName : nil,
                              countdownFrom: f.live ? now : countdownFrom, moodMeeting: moodMeeting)
        } else if isActive {
            // Back in the app with nothing close: drop an early one; it'll come back when it's due.
            liveActivity.end()
        }
    }

    /// iOS ends Live Activities after 8 hours; don't start one so early it would expire first.
    private static let earlyStartLimit: TimeInterval = 7 * 3600

    // MARK: - Accounts (same shape as the Mac's AppState)

    private func syncFeeds(fetch: Bool) {
        var next: [ICSProvider] = []
        var fresh: [ICSProvider] = []
        for feed in prefs.icsFeeds where feed.enabled {
            if let existing = icsProviders.first(where: { $0.feed == feed }) {
                next.append(existing)
            } else {
                let p = ICSProvider(feed: feed)
                p.onChange = { [weak self] in self?.refresh() }
                next.append(p)
                fresh.append(p)
            }
        }
        icsProviders = next
        refresh()
        if fetch { for p in fresh { Task { await p.refreshRemote() } } }
    }

    private func syncGoogle(fetch: Bool) {
        var next: [GoogleCalendarProvider] = []
        var fresh: [GoogleCalendarProvider] = []
        for account in googleAuth.accounts {
            if let existing = googleProviders.first(where: { $0.accountID == account.id }) {
                next.append(existing)
            } else {
                let p = GoogleCalendarProvider(accountID: account.id, auth: googleAuth)
                p.onChange = { [weak self] in self?.refresh() }
                next.append(p)
                fresh.append(p)
            }
        }
        googleProviders = next
        refresh()
        if fetch { for p in fresh { Task { await p.refreshRemote() } } }
    }

    private func syncMicrosoft(fetch: Bool) {
        var next: [MicrosoftCalendarProvider] = []
        var fresh: [MicrosoftCalendarProvider] = []
        for account in microsoftAuth.accounts {
            if let existing = microsoftProviders.first(where: { $0.accountID == account.id }) {
                next.append(existing)
            } else {
                let p = MicrosoftCalendarProvider(accountID: account.id, auth: microsoftAuth)
                p.onChange = { [weak self] in self?.refresh() }
                next.append(p)
                fresh.append(p)
            }
        }
        microsoftProviders = next
        refresh()
        if fetch { for p in fresh { Task { await p.refreshRemote() } } }
    }

    func googleSignIn() async throws {
        let account = try await googleAuth.signIn()
        syncGoogle(fetch: false)
        await googleProviders.first { $0.accountID == account.id }?.refreshRemote()
        refresh()
    }

    func googleSignOut(_ account: GoogleAccount) {
        googleAuth.signOut(account)
        prefs.filters.disabledCalendarIDs = prefs.filters.disabledCalendarIDs.filter { !$0.hasPrefix("gcal:\(account.id):") }
        syncGoogle(fetch: false)
    }

    func microsoftSignIn() async throws {
        let account = try await microsoftAuth.signIn()
        syncMicrosoft(fetch: false)
        await microsoftProviders.first { $0.accountID == account.id }?.refreshRemote()
        refresh()
    }

    func microsoftSignOut(_ account: MicrosoftAccount) {
        microsoftAuth.signOut(account)
        prefs.filters.disabledCalendarIDs = prefs.filters.disabledCalendarIDs.filter { !$0.hasPrefix("msft:\(account.id):") }
        syncMicrosoft(fetch: false)
    }

    // MARK: - URLs

    /// cadence-pair://… (scanned QR or pasted link) and cadence-companion://join?id=… (Live Activity).
    @discardableResult
    func open(_ url: URL) -> Bool {
        if spotify.handle(url) { return true }
        if let invite = PairingInvite(url: url) {
            // A different Mac: its agenda replaces the old one's when it connects; don't show the old one meanwhile.
            if invite.macID != link.mac?.id {
                snapshot = nil
                UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
            }
            link.pair(invite)
            return true
        }
        if url.scheme == "cadence-companion", url.host == "join",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
            join(id: id)
            return true
        }
        return false
    }
}
