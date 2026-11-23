import BackgroundTasks
import CadenceCore
import Foundation
import Observation
import UIKit
import WidgetKit

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
            if prefs.sampleCalendarSince != oldValue.sampleCalendarSince { syncSample() }
            scheduleBackgroundWork()
        }
    }

    private(set) var now = Date()
    private(set) var calendars: [CalendarInfo] = []
    /// This phone's own merged, filtered meetings.
    private(set) var ownMeetings: [Meeting] = []
    /// Each paired Mac's last snapshot, by Mac id (kept after disconnecting, shown when there's nothing else).
    private(set) var snapshots: [String: CompanionSnapshot] = PhoneState.loadSnapshots()
    /// The Macs' agendas in priority order: the connected Macs while any is, else every paired Mac's
    /// saved copy. Finds each Mac's own copy of a meeting for Join, Snooze, prompts and enrichments.
    private(set) var agenda = MultiMacAgenda(agendas: [])
    /// `agenda` as one snapshot: meetings merged, mutes carried across, settings from the first Mac.
    private(set) var snapshot: CompanionSnapshot?
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
    /// The system media volume, for the Mac's volume keys.
    let volume = PhoneVolume()
    /// What a Mac is playing (Music or Spotify there), while connected: the first Mac in the list
    /// that's playing, else the first that has something paused.
    private(set) var macMedia: CompanionMedia?
    private(set) var macArtwork: UIImage?
    /// The Mac `macMedia` is from, which the desk's media controls drive.
    private(set) var macMediaSource: String?
    @ObservationIgnored private var macMediaByMac: [String: CompanionMedia] = [:]
    @ObservationIgnored private var macArtworkByMac: [String: UIImage] = [:]
    /// Which Macs each pop-up came from, with the id (meeting or clash key) that Mac knows it by, so
    /// the same invite or clash from two Macs shows once and the answer reaches both.
    @ObservationIgnored private var inviteSources: [String: [(macID: String, meetingID: String)]] = [:]
    @ObservationIgnored private var clashSources: [String: [(macID: String, clash: CompanionClash)]] = [:]
    @ObservationIgnored private var sentMedia: CompanionMedia?
    @ObservationIgnored private var sentVolume: (level: Double, muted: Bool)?
    @ObservationIgnored let audioHandoff = MeetingAudioHandoff()
    @ObservationIgnored let notifier = PhoneNotifier()
    @ObservationIgnored let liveActivity = LiveActivityController()

    let googleAuth = GoogleAuth()
    let microsoftAuth = MicrosoftAuth()
    @ObservationIgnored private let eventKit = EventKitProvider()
    private(set) var googleProviders: [GoogleCalendarProvider] = []
    private(set) var microsoftProviders: [MicrosoftCalendarProvider] = []
    private(set) var icsProviders: [ICSProvider] = []
    /// "Try with sample meetings", while it's on.
    private(set) var sample: SampleCalendar?
    @ObservationIgnored private var providers: [CalendarProvider] {
        [eventKit] + googleProviders + microsoftProviders + icsProviders + (sample.map { [$0] } ?? [])
    }

    @ObservationIgnored private var planner = AlertPlanner()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastRemoteRefresh: Date?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var started = false

    private init() {
        prefs = PhonePrefs.load()
        Self.migrateSnapshot(to: link.macs.first?.id)
        snapshots = Self.loadSnapshots()
        rebuildAgenda()
    }

    /// Rebuilds `agenda` and `snapshot` from the saved snapshots and which Macs are connected.
    private func rebuildAgenda() {
        let pool = link.isConnected ? link.connected : link.links
        let sources = pool.compactMap { l in snapshots[l.mac.id].map { MacAgenda(macID: l.mac.id, snapshot: $0) } }
        let merged = MultiMacAgenda(agendas: sources)
        agenda = merged
        snapshot = sources.first.map { first in
            var s = first.snapshot
            guard sources.count > 1 else { return s }
            s.meetings = merged.meetings
            s.suppressedIDs = merged.suppressedIDs
            s.agendaOnlyIDs = merged.agendaOnlyIDs
            s.generatedAt = sources.map(\.snapshot.generatedAt).min() ?? s.generatedAt
            return s
        }
    }

    /// The Macs changed (connected, dropped, paired, unpaired or reordered).
    private func linksChanged() {
        let paired = Set(link.macs.map(\.id))
        if snapshots.keys.contains(where: { !paired.contains($0) }) {
            snapshots = snapshots.filter { paired.contains($0.key) }
            Self.saveSnapshots(snapshots)
        }
        rebuildAgenda()
        sourcesChanged()
        // A Mac that just connected hears what's playing here and the volume.
        sentMedia = nil
        sentVolume = nil
        updateMacMedia()
        planner.prune(keeping: meetings + ownMeetings)
        updateLiveActivity()
        updateWidgets()
    }

    private func updateMacMedia() {
        let order = link.connected.map(\.mac.id)
        let source = order.first { macMediaByMac[$0]?.isPlaying == true } ?? order.first { macMediaByMac[$0] != nil }
        macMediaSource = source
        macMedia = source.flatMap { macMediaByMac[$0] }
        macArtwork = source.flatMap { macArtworkByMac[$0] }
    }

    // MARK: - Source of truth

    /// Connected: the Mac's meetings. Otherwise the Mac's last copy merged with any calendars on this
    /// phone, so the agenda, alerts and notifications carry on without the Mac.
    var meetings: [Meeting] {
        #if DEBUG
        if let previewMeetings { return previewMeetings }
        #endif
        if link.isConnected, let snapshot { return snapshot.meetings }
        return offlineMeetings
    }

    /// The Mac's last snapshot plus this phone's own meetings, duplicates merged.
    private var offlineMeetings: [Meeting] {
        guard let cached = macCopy, !cached.isEmpty else { return ownMeetings }
        guard !ownMeetings.isEmpty else { return cached }
        return MeetingDeduplicator.dedupe((cached + ownMeetings).sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) })
    }

    #if DEBUG
    /// `-previewDesk done|long`: a canned agenda for checking the desk layout.
    private var previewMeetings: [Meeting]?
    #endif

    /// The cached Mac meetings, while paired (unpairing drops them).
    private var macCopy: [Meeting]? { link.mac == nil ? nil : snapshot?.meetings }

    var usingMac: Bool { link.isConnected && snapshot != nil }
    /// Showing the Mac's saved agenda while it's out of reach.
    var usingMacCopy: Bool { !link.isConnected && !(macCopy ?? []).isEmpty }
    /// When the saved agenda was last brought up to date.
    var macCopyDate: Date? { snapshot?.generatedAt }
    var hasOwnSources: Bool { calendarAccess || !googleProviders.isEmpty || !microsoftProviders.isEmpty || !icsProviders.isEmpty }
    /// Somewhere real for meetings to come from: a calendar on this phone or a paired Mac.
    var hasRealSource: Bool { hasOwnSources || !link.links.isEmpty }
    /// Showing the made-up sample meetings.
    var usingSample: Bool { sample != nil }
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

    // MARK: - Working day

    /// Working hours and breaks: the Mac's while paired (it owns them), else this phone's own.
    var schedule: WorkSchedule {
        #if DEBUG
        if let previewSchedule { return previewSchedule }
        #endif
        return scheduleFromMac ?? prefs.workSchedule
    }

    /// The paired Mac's schedule, when it sent one.
    var scheduleFromMac: WorkSchedule? { link.mac == nil ? nil : snapshot?.workSchedule }

    #if DEBUG
    /// `-previewDesk morning|focus|break|wrap`: a schedule placed around now.
    private var previewSchedule: WorkSchedule?
    #endif

    /// Today's meetings that count: not muted by a clash choice or agenda-only.
    private var countedMeetings: [Meeting] {
        let hidden = suppressed
        return meetings.filter { !hidden.contains($0.id) && !isAgendaOnly($0) }
    }

    /// Where we are in the working day (nil when working hours are off).
    var moment: DayMoment? {
        DayPlanner.moment(meetings: countedMeetings, schedule: schedule, now: now, skipping: suppressed)
    }

    /// Minutes of focus time had so far today.
    var focusSoFar: Int { DayPlanner.focusSoFar(meetings: countedMeetings, schedule: schedule, now: now) }

    /// Today's and tomorrow's working-day stretches, flattened for the widgets and Live Activity.
    private func daySegments(from day: Date) -> [WidgetSegment] {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let counted = countedMeetings, hidden = suppressed
        return [day, tomorrow].flatMap { DayPlanner.segments(meetings: counted, schedule: schedule, day: $0, skipping: hidden) }
            .map { WidgetSegment(kind: $0.kind.rawValue, start: $0.start, end: $0.end, title: $0.title, detail: $0.detail) }
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
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-previewDesk") {
            let args = ProcessInfo.processInfo.arguments
            loadPreviewDesk(args.indices.contains(i + 1) ? args[i + 1] : "long")
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
        link.onMessage = { [weak self] id, message in self?.handle(message, from: id) }
        link.onDisconnected = { [weak self] id in self?.macDisconnected(id) }
        link.onLinksChanged = { [weak self] in self?.linksChanged() }
        desk.onChange = { [weak self] in self?.displayChanged() }
        notifier.onJoin = { [weak self] id in self?.join(id: id) }
        notifier.isForegroundSuppressed = { [weak self] in
            // On screen we show our own overlay, and the Mac's reminders arrive over the link.
            guard let self else { return false }
            return self.isActive
        }
        notifier.setUp()
        Keychain.keepOnThisDevice()
        syncGoogle(fetch: false)
        syncMicrosoft(fetch: false)
        syncFeeds(fetch: false)
        calendarAccess = eventKit.isAuthorized
        syncSample()
        hadRealSource = hasRealSource
        // Already set up before the welcome existed: no need to show it.
        if !prefs.welcomeSeen && hasRealSource { prefs.welcomeSeen = true }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-previewWelcome") { prefs.welcomeSeen = false }
        // -previewSample: past the welcome, with the sample meetings on.
        if ProcessInfo.processInfo.arguments.contains("-previewSample") { prefs.welcomeSeen = true; setSample(true) }
        // -previewHome: past the welcome with nothing connected (the empty home screen).
        if ProcessInfo.processInfo.arguments.contains("-previewHome") { prefs.welcomeSeen = true; setSample(false) }
        #endif
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
        updateWidgets()
        sourcesChanged()
    }

    // MARK: - Sample meetings & first sources

    func setSample(_ on: Bool) { prefs.sampleCalendarSince = on ? Date() : nil }

    private func syncSample() {
        if let since = prefs.sampleCalendarSince {
            if sample?.since != since { sample = SampleCalendar(since: since) }
        } else {
            sample = nil
        }
        refresh()
    }

    @ObservationIgnored private var hadRealSource: Bool?

    /// The first real calendar or Mac just arrived: the sample meetings make way, and (once past the
    /// welcome, which asks on its own page) it's the moment to ask about notifications.
    private func sourcesChanged() {
        // Not tracked until start() has loaded every account, so launching isn't mistaken for one arriving.
        guard let had = hadRealSource else { return }
        let has = hasRealSource
        hadRealSource = has
        guard !had, has else { return }
        if prefs.sampleCalendarSince != nil { prefs.sampleCalendarSince = nil }
        if prefs.welcomeSeen { Task { await askForNotifications() } }
    }

    /// Asks once for notifications (iOS shows its prompt only the first time), then schedules them.
    func askForNotifications() async {
        _ = await notifier.requestAuthorization()
        scheduleBackgroundWork()
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

    private func handle(_ message: CompanionMessage, from macID: String) {
        switch message {
        case .welcome:
            break // the Mac decides alerts while connected; the planner keeps what's fired for later
        case .snapshot(let snap):
            snapshots[macID] = snap
            Self.saveSnapshots(snapshots)
            rebuildAgenda()
            planner.prune(keeping: meetings + ownMeetings)
            updateLiveActivity()
            updateWidgets()
        case .alert(let meeting):
            // Remembered, so it doesn't fire a second time if the link drops before the meeting starts.
            planner.markFired(meeting)
            // Several Macs alerting for the same meeting: one alert is enough.
            if let alerting, alerting.id == meeting.id || MeetingDeduplicator.isSameMeeting(alerting, meeting) { break }
            present(meeting)
        case .dismissAlert(let id):
            guard let alerting else { break }
            let theirs = snapshots[macID]?.meetings.first { $0.id == id }
            if alerting.id == id || theirs.map({ MeetingDeduplicator.isSameMeeting($0, alerting) }) == true { self.alerting = nil }
        case .invitePrompt(let invites):
            var fresh = false
            for invite in invites {
                if let shown = invitePrompts.first(where: { $0.meeting.id == invite.meeting.id
                    || MeetingDeduplicator.isSameMeeting($0.meeting, invite.meeting) }) {
                    var sources = inviteSources[shown.meeting.id] ?? []
                    if !sources.contains(where: { $0.macID == macID }) { sources.append((macID, invite.meeting.id)) }
                    inviteSources[shown.meeting.id] = sources
                } else {
                    invitePrompts.append(invite)
                    inviteSources[invite.meeting.id] = [(macID, invite.meeting.id)]
                    fresh = true
                }
            }
            if fresh { haptic(.success) }
        case .inviteHandled(let id):
            // Answered on that Mac (or another of its phones): close it, whichever Mac it came from.
            let handled = invitePrompts.filter { prompt in
                (inviteSources[prompt.meeting.id] ?? []).contains { $0.macID == macID && $0.meetingID == id }
            }
            for prompt in handled { inviteSources[prompt.meeting.id] = nil }
            invitePrompts.removeAll { p in handled.contains { $0.meeting.id == p.meeting.id } }
        case .clashPrompt(let clash):
            if let shown = clashPrompts.first(where: { Self.sameClash($0, clash) }) {
                var sources = clashSources[shown.key] ?? []
                if !sources.contains(where: { $0.macID == macID }) { sources.append((macID, clash)) }
                clashSources[shown.key] = sources
                break
            }
            clashPrompts.append(clash)
            clashSources[clash.key] = [(macID, clash)]
            haptic(.warning)
        case .clashHandled(let key):
            let handled = clashPrompts.filter { prompt in
                (clashSources[prompt.key] ?? []).contains { $0.macID == macID && $0.clash.key == key }
            }
            for prompt in handled { clashSources[prompt.key] = nil }
            clashPrompts.removeAll { p in handled.contains { $0.key == p.key } }
        case .media(let media):
            if let art = media?.artwork { macArtworkByMac[macID] = UIImage(data: art) }
            else if media?.trackID != macMediaByMac[macID]?.trackID { macArtworkByMac[macID] = nil }
            macMediaByMac[macID] = media
            updateMacMedia()
        case .mediaCommand(let command):
            applyMediaCommand(command)
        case .reminder(let reminder):
            // The same heads-up from two Macs: show it once.
            if let banner, banner.title == reminder.title, banner.body == reminder.body { break }
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

    /// A Mac's link dropped: it takes back its pop-ups and stops being a media source.
    private func macDisconnected(_ macID: String) {
        macMediaByMac[macID] = nil
        macArtworkByMac[macID] = nil
        for (key, sources) in inviteSources { inviteSources[key] = sources.filter { $0.macID != macID } }
        for (key, sources) in clashSources { clashSources[key] = sources.filter { $0.macID != macID } }
        invitePrompts.removeAll { inviteSources[$0.meeting.id]?.isEmpty ?? true }
        clashPrompts.removeAll { clashSources[$0.key]?.isEmpty ?? true }
        inviteSources = inviteSources.filter { !$0.value.isEmpty }
        clashSources = clashSources.filter { !$0.value.isEmpty }
        updateMacMedia()
    }

    /// Two Macs' prompts for the same double-booking: the same meetings, in any order.
    private static func sameClash(_ a: CompanionClash, _ b: CompanionClash) -> Bool {
        a.key == b.key || (a.meetings.count == b.meetings.count
            && a.meetings.allSatisfy { m in b.meetings.contains { MeetingDeduplicator.isSameMeeting($0, m) } })
    }

    private static let snapshotsKey = "Cadence.companion.snapshots"
    /// Before several Macs: the one Mac's snapshot.
    private static let legacySnapshotKey = "Cadence.companion.snapshot"

    /// Optimistic change to one Mac's mirrored enrichments (its next snapshot replaces it).
    func updateSnapshotEnrichments(macID: String, _ body: (inout EnrichmentBook) -> Void) {
        guard var snap = snapshots[macID] else { return }
        var book = snap.enrichments ?? EnrichmentBook()
        body(&book)
        snap.enrichments = book
        snapshots[macID] = snap
        rebuildAgenda()
    }

    private static func migrateSnapshot(to macID: String?) {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: legacySnapshotKey) else { return }
        defaults.removeObject(forKey: legacySnapshotKey)
        guard let macID, defaults.data(forKey: snapshotsKey) == nil,
              let snap = try? JSONDecoder().decode(CompanionSnapshot.self, from: data) else { return }
        saveSnapshots([macID: snap])
    }

    private static func loadSnapshots() -> [String: CompanionSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: snapshotsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CompanionSnapshot].self, from: data)) ?? [:]
    }

    private static func saveSnapshots(_ snaps: [String: CompanionSnapshot]) {
        if let data = try? JSONEncoder().encode(snaps) { UserDefaults.standard.set(data, forKey: snapshotsKey) }
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
        if Int(now.timeIntervalSince1970) % 30 == 0 { updateLiveActivity(); updateWidgets() }
        if isActive && (displaying || link.isConnected) {
            nowPlaying.poll()
            // Something's playing that isn't Music: if it's Spotify, pick up its track quietly.
            if nowPlaying.otherPlaying && prefs.mediaApp == .spotify {
                spotify.connectIfPossible()
                // Connected but no track yet (state can lag a reconnect): ask again.
                if spotify.connected && (spotify.trackURI == nil || !spotify.isPlaying) { spotify.refreshState() }
            }
        }
        syncMediaToMac()
        if link.isConnected {
            if displaying { volume.poll() }
            syncVolumeToMac()
        }
    }

    /// The Mac's mini-player shows the phone's volume.
    private func syncVolumeToMac() {
        guard link.isConnected else { sentVolume = nil; return }
        let current = (level: volume.level, muted: volume.muted)
        if let sent = sentVolume, abs(sent.level - current.level) < 0.001, sent.muted == current.muted { return }
        sentVolume = current
        link.broadcast(.volume(level: current.level, muted: current.muted))
    }

    /// Tells the Mac when what's playing here changes, so its media keys and Now Playing follow.
    private func syncMediaToMac() {
        guard link.isConnected else { sentMedia = nil; return }
        let current = phoneMedia(includeArtwork: false)
        guard current != sentMedia else { return }
        let newTrack = current?.trackID != sentMedia?.trackID
        sentMedia = current
        link.broadcast(.media(newTrack ? phoneMedia(includeArtwork: true) : current))
    }

    private func phoneMedia(includeArtwork: Bool) -> CompanionMedia? {
        if !nowPlaying.musicPlaying, let s = spotify.companionMedia(includeArtwork: includeArtwork) { return s }
        return nowPlaying.companionMedia(preferred: prefs.mediaApp, includeArtwork: includeArtwork)
    }

    /// Mac media keys / Control Center (via the Mac), aimed at what's playing on this phone.
    private func applyMediaCommand(_ command: MediaCommand) {
        if command.isVolume {
            // Only from the desk display: the volume view only works while it's on screen.
            guard displaying else { return }
            volume.apply(command)
            syncVolumeToMac()
            return
        }
        let np = nowPlaying
        // Same rule as the desk's own controls (`spotifyActive`), so a key does what the buttons do.
        if spotifyActive || (spotify.connected && !np.musicPlaying && !np.hasTrack) {
            switch command {
            case .play: spotify.play()
            case .pause: spotify.pause()
            case .togglePlayPause: spotify.togglePlay()
            case .next: spotify.next()
            case .previous: spotify.previous()
            case .volumeUp, .volumeDown, .toggleMute: break
            }
            return
        }
        // Nothing known to resume: Music can still pick up its last queue if it's the chosen app.
        let canResume = np.hasTrack || (prefs.mediaApp == .appleMusic && np.authorized)
        switch command {
        // From the Mac's keys a resume never opens the app: that would cover the desk display.
        case .play: if canResume { np.resumeMusic() } else if np.othersInterrupted { resumeOthers(openIfStill: false) }
        case .pause: pauseMedia()
        case .togglePlayPause:
            if np.isPlaying { pauseMedia() }
            else if canResume { np.resumeMusic() }
            else if np.othersInterrupted { resumeOthers(openIfStill: false) }
        case .next: np.next()
        case .previous: np.previous()
        case .volumeUp, .volumeDown, .toggleMute: break
        }
    }

    /// Desk controls aimed at the Mac's player.
    func controlMac(_ command: MediaCommand) {
        guard let source = macMediaSource else { return }
        link.send(.mediaCommand(command), to: source)
        if var m = macMedia, command == .togglePlayPause || command == .play || command == .pause {
            m.isPlaying = command == .togglePlayPause ? !m.isPlaying : command == .play
            macMedia = m
            macMediaByMac[source] = m
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
        // Tapping through to Music is when to ask to see what it's playing (not on opening the desk):
        // ask first, then open Music once it's answered.
        if prefs.mediaApp == .appleMusic && nowPlaying.canPrompt {
            nowPlaying.start(prompt: true) { [weak self] in self?.openMediaApp() }
            return
        }
        UIApplication.shared.open(prefs.mediaApp.url)
    }

    /// The desk's idle media button. For Spotify it also hooks Cadence up: one tap opens Spotify,
    /// approves (first time), starts your last track and comes back with the controls showing.
    func launchMedia() {
        if nowPlaying.othersInterrupted { resumeOthers(openIfStill: true); return }
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
        else if nowPlaying.otherPlaying {
            audioHandoff.interruptOthers()
            nowPlaying.noteInterruptedOthers()
        }
    }

    /// Asks the app Cadence stopped (YouTube Music, a podcast…) to carry on. Not every player
    /// does; `openIfStill` opens the preferred app if nothing's playing a moment later.
    func resumeOthers(openIfStill: Bool) {
        nowPlaying.clearInterruptedOthers()
        audioHandoff.resumeOthers()
        guard openIfStill else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.audioHandoff.otherAudioPlaying else { return }
            self.openMediaApp()
        }
    }

    /// Spotify connected and the one playing (or just paused): it gets the controls.
    var spotifyActive: Bool {
        guard spotify.connected, !nowPlaying.musicPlaying else { return false }
        return spotify.showsControls(now: now) || (nowPlaying.otherPlaying && prefs.mediaApp == .spotify)
    }

    private func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    // MARK: - Actions

    /// The connected Mac Join opens `meeting` on (see `MacJoinRouting`), or nil for this phone.
    func joinMac(for meeting: Meeting) -> MacLink? {
        let connected = link.connected
        guard !connected.isEmpty else { return nil }
        let target = MacJoinRouting.target(
            sources: agenda.copies(of: meeting).map(\.macID), connected: connected.map(\.mac.id),
            canTakeLinks: Set(connected.filter { $0.supports(.joinMeeting) }.map(\.mac.id)),
            link: meeting.joinLink, preferPriorityMac: prefs.joinOnPriorityMac)
        return target.flatMap { link.link($0) }
    }

    /// "Join on Work laptop", or nil when Join opens on this phone.
    func joinMacName(for meeting: Meeting) -> String? { joinMac(for: meeting)?.mac.displayName }

    /// Join: on a connected Mac (the first in the list that has the meeting, or the first Mac for a
    /// web link when the user prefers that), otherwise on this phone. Other Macs that have it close
    /// their alert.
    func join(_ meeting: Meeting) {
        markJoined(meeting)
        let copies = link.isConnected ? agenda.copies(of: meeting) : []
        if let target = joinMac(for: meeting) {
            let targetID = target.mac.id
            if let own = copies.first(where: { $0.macID == targetID }) {
                target.send(.join(meetingID: own.meeting.id))
            } else {
                target.send(.joinMeeting(meeting))
            }
            for copy in copies where copy.macID != targetID { link.send(.dismiss(meetingID: copy.meeting.id), to: copy.macID) }
        } else {
            if let url = meeting.joinLink.flatMap(MeetingLinkDetector.trusted)?.url { UIApplication.shared.open(url) }
            for copy in copies { link.send(.dismiss(meetingID: copy.meeting.id), to: copy.macID) }
        }
        if alerting?.id == meeting.id { alerting = nil }
        updateLiveActivity()
    }

    // MARK: - Joined meetings

    /// Meetings joined from this phone, by id, with when they end (so old ones can be dropped).
    @ObservationIgnored private var joinedHere: [String: Date] = PhoneState.loadJoined()
    private static let joinedKey = "Cadence.phone.joinedMeetings.v1"

    private static func loadJoined() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: joinedKey),
              let all = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return all.filter { $0.value > Date() }
    }

    private func markJoined(_ meeting: Meeting) {
        let now = Date()
        joinedHere = joinedHere.filter { $0.value > now }
        for id in Set([meeting.id] + agenda.copies(of: meeting).map(\.meeting.id)) { joinedHere[id] = meeting.end }
        if let data = try? JSONEncoder().encode(joinedHere) { UserDefaults.standard.set(data, forKey: Self.joinedKey) }
    }

    /// Joined here, or on any Mac that has it (from the Mac's last snapshot).
    func hasJoined(_ meeting: Meeting) -> Bool {
        if joinedHere[meeting.id] != nil { return true }
        return agenda.copies(of: meeting).contains { copy in
            joinedHere[copy.meeting.id] != nil || snapshots[copy.macID]?.joinedIDs?.contains(copy.meeting.id) == true
        }
    }

    /// Join by id (from a notification or the Live Activity). Waits briefly for the Mac link to come
    /// back after the app wakes up, then falls back to joining on the phone.
    func join(id: String) {
        Task {
            for _ in 0..<20 where !link.isConnected && !link.links.isEmpty && link.status != .unpaired {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let meeting = meeting(id: id) else { return }
            join(meeting)
        }
    }

    func meeting(id: String) -> Meeting? {
        meetings.first { $0.id == id } ?? ownMeetings.first { $0.id == id } ?? agenda.meeting(id: id)
            ?? link.macs.lazy.compactMap { [snapshots] in snapshots[$0.id]?.meetings.first { $0.id == id } }.first
    }

    func snooze(_ meeting: Meeting, seconds: TimeInterval = 60) {
        if link.isConnected {
            for copy in agenda.copies(of: meeting) { link.send(.snooze(meetingID: copy.meeting.id, seconds: seconds), to: copy.macID) }
        } else {
            planner.snooze(meeting, until: Date().addingTimeInterval(seconds))
        }
        alerting = nil
    }

    /// Answer an invite pop-up. nil reply = open it in Calendar on the Mac.
    /// The answer goes to one Mac (the first in the list that sent it, so it's sent once); any
    /// other Mac that sent the same invite just closes its pop-up.
    func answer(_ invite: CompanionInvite, _ reply: RSVP?) {
        let sources = orderedInviteSources(invite)
        if let first = sources.first { link.send(.rsvp(meetingID: first.meetingID, reply: reply), to: first.macID) }
        for other in sources.dropFirst() { link.send(.inviteLater(meetingID: other.meetingID), to: other.macID) }
        closeInvite(invite)
    }

    /// Close an invite pop-up without answering.
    func later(_ invite: CompanionInvite) {
        for source in orderedInviteSources(invite) { link.send(.inviteLater(meetingID: source.meetingID), to: source.macID) }
        closeInvite(invite)
    }

    private func orderedInviteSources(_ invite: CompanionInvite) -> [(macID: String, meetingID: String)] {
        let sources = inviteSources[invite.meeting.id] ?? []
        return link.macs.compactMap { mac in sources.first { $0.macID == mac.id } }
    }

    private func closeInvite(_ invite: CompanionInvite) {
        inviteSources[invite.meeting.id] = nil
        invitePrompts.removeAll { $0.meeting.id == invite.meeting.id }
    }

    /// Settle a clash pop-up: a meeting id, "all", or nil for "decide later". Each Mac that raised it
    /// hears the choice in its own meeting ids.
    func resolve(_ clash: CompanionClash, choice: String?) {
        let chosen = choice.flatMap { id in clash.meetings.first { $0.id == id } }
        for source in clashSources[clash.key] ?? [] {
            var theirs = choice
            if let chosen {
                theirs = source.clash.meetings.first { $0.id == chosen.id || MeetingDeduplicator.isSameMeeting($0, chosen) }?.id ?? choice
            }
            link.send(.resolveClash(key: source.clash.key, choice: theirs), to: source.macID)
        }
        clashSources[clash.key] = nil
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

    #if DEBUG
    /// `-previewDesk done`: today's meetings are all over. `-previewDesk long`: a meeting with a very
    /// long title coming up, with a join link, and a couple more after it.
    func loadPreviewDesk(_ kind: String) {
        func m(_ id: String, _ title: String, _ inMin: Double, _ len: Double, link: Bool = false) -> Meeting {
            let cal = CalendarInfo(id: "preview-desk", title: "Work", sourceTitle: "Preview", color: RGBAColor(red: 0.35, green: 0.45, blue: 1))
            return Meeting(id: "desk-\(id)", title: title, start: Date().addingTimeInterval(inMin * 60),
                           end: Date().addingTimeInterval((inMin + len) * 60), calendar: cal,
                           joinLink: link ? MeetingLink(service: .zoom, url: URL(string: "https://example.com/cadence-preview")!) : nil)
        }
        func schedule(start: Double, end: Double, breakFrom: Double? = nil, breakTo: Double? = nil) -> WorkSchedule {
            // Minutes from now, as today's minutes after midnight (kept within the day).
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let nowMin = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
            func clamp(_ v: Double) -> Int { Int(min(24 * 60 - 1, max(0, nowMin + v))) }
            let days = (1...7).map { _ in WorkDay(enabled: true, start: clamp(start), end: clamp(end)) }
            let breaks = breakFrom.map { [WorkBreak(id: "preview-lunch", name: "Lunch", start: clamp($0), end: clamp(breakTo ?? $0 + 60))] } ?? []
            return WorkSchedule(days: days, breaks: breaks)
        }
        switch kind {
        case "done":
            previewMeetings = [m("a", "Standup", -120, 15), m("b", "Design Review", -60, 30)]
        case "morning":
            previewSchedule = schedule(start: 40, end: 520)
            previewMeetings = [m("a", "Standup", 55, 15, link: true), m("b", "Design Review", 180, 30)]
        case "focus":
            previewSchedule = schedule(start: -120, end: 300, breakFrom: 200)
            previewMeetings = [m("a", "Standup", -100, 15), m("b", "Design Review", 95, 30, link: true)]
        case "break":
            previewSchedule = schedule(start: -200, end: 240, breakFrom: -15, breakTo: 35)
            previewMeetings = [m("a", "Standup", -180, 15), m("b", "Design Review", 70, 30, link: true)]
        case "wrap":
            previewSchedule = schedule(start: -540, end: -20, breakFrom: -300)
            previewMeetings = [m("a", "Standup", -510, 15), m("b", "Design Review", -400, 45), m("c", "1:1 with Sam", -120, 30)]
        default:
            previewMeetings = [
                m("long", "Quarterly cross-functional planning and roadmap alignment session with the platform, design and partnerships teams", 12, 45, link: true),
                m("c", "1:1 with Sam", 75, 30), m("d", "Vendor call", 130, 30),
            ]
        }
        desk.set(true)
    }
    #endif

    func dismissAlert() {
        if let alerting, link.isConnected {
            for copy in agenda.copies(of: alerting) { link.send(.dismiss(meetingID: copy.meeting.id), to: copy.macID) }
        }
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
        // Not for the sample meetings: one an hour would be a lot of notifications.
        notifier.reschedule(meetings: offlineMeetings.filter { !suppressed.contains($0.id) && $0.calendar.id != SampleCalendar.calendarID }, prefs: prefs,
                            schedule: schedule, skipping: suppressed)
        updateLiveActivity()
        updateWidgets()
    }

    /// Hands today's and tomorrow's meetings to the Home and Lock Screen widgets (through the App
    /// Group) and asks them to redraw, only when something they show changed. Uses `meetings`, so
    /// the widgets follow the Mac while connected and carry on from the saved copy when not.
    private func updateWidgets() {
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.date(byAdding: .day, value: 2, to: from) ?? from.addingTimeInterval(172_800)
        let hidden = suppressed
        let upcoming = meetings
            .filter { !$0.isAllDay && $0.end > from && $0.start < to && !hidden.contains($0.id) && !isAgendaOnly($0) }
            .map { m -> WidgetMeeting in
                let c = m.displayColor
                return WidgetMeeting(id: m.id, title: m.title, start: m.start, end: m.end,
                                     red: c.red, green: c.green, blue: c.blue, hasLink: m.joinLink != nil)
            }
        let tomorrowFromHour = prefs.widgetShowsTomorrow ? prefs.widgetTomorrowHour : nil
        let segments = schedule.enabled ? daySegments(from: from) : nil
        guard upcoming != lastWidgetMeetings || tomorrowFromHour != lastWidgetTomorrowHour || segments != lastWidgetSegments else { return }
        lastWidgetMeetings = upcoming
        lastWidgetTomorrowHour = tomorrowFromHour
        lastWidgetSegments = segments
        WidgetSchedule(meetings: upcoming, generatedAt: Date(), tomorrowFromHour: tomorrowFromHour, segments: segments).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    @ObservationIgnored private var lastWidgetMeetings: [WidgetMeeting]?
    @ObservationIgnored private var lastWidgetTomorrowHour: Int??
    @ObservationIgnored private var lastWidgetSegments: [WidgetSegment]??

    /// Live Activity (Lock Screen, StandBy, Dynamic Island): a countdown once the next meeting is within
    /// `liveActivityLeadMinutes`. iOS only lets an app start one while it's open, so when leaving
    /// (`leaving`) one for a later meeting today starts early, showing the start time, and turns into
    /// the countdown by itself at the lead time.
    private func updateLiveActivity(leaving: Bool = false) {
        guard prefs.liveActivityEnabled else { liveActivity.end(keepMissed: false); return }
        let now = Date()
        let lead = Double(prefs.liveActivityLeadMinutes) * 60
        // Focus time or a break with no meeting close: count that down instead.
        let segment = schedule.enabled
            ? daySegments(from: Calendar.current.startOfDay(for: now)).first { $0.contains(now) && $0.countsDown } : nil
        // Unlike the desk, a joined meeting drops out, and a missed one once it's lingered long enough.
        let hidden = suppressed
        let plan = ActivityPlanner.focus(meetings: meetings, now: now, isHidden: { hidden.contains($0.id) },
                                         hasJoined: hasJoined, linger: prefs.liveActivityMissedLinger)
        let meetingDue = plan.map { $0.live || $0.meeting.start.timeIntervalSince(now) <= max(lead, WidgetSchedule.momentYield) } ?? false
        if let segment, !meetingDue {
            liveActivity.show(segment: segment, next: plan?.meeting ?? next)
            return
        }
        guard let f = plan else { liveActivity.end(); return }
        let countdownFrom = f.meeting.start.addingTimeInterval(-lead)
        let early = leaving && Calendar.current.isDate(f.meeting.start, inSameDayAs: now)
            && f.meeting.start.timeIntervalSince(now) < Self.earlyStartLimit
        let started = f.meeting.start <= now
        if started || now >= countdownFrom || early {
            let after = todayMeetings.first { $0.start >= f.meeting.start && $0.end > now && $0.id != f.meeting.id
                && !hidden.contains($0.id) && !isAgendaOnly($0) }
            // Same as the Mac's menu bar: the mood (and the icon's colour) follow the next meeting to start.
            let moodMeeting = started ? after.flatMap { $0.start > now ? $0 : nil } : f.meeting
            liveActivity.show(f.meeting, live: f.live, next: after, onMac: joinMacName(for: f.meeting),
                              countdownFrom: started ? now : countdownFrom, moodMeeting: moodMeeting,
                              missedUntil: f.missedUntil, showsMissed: prefs.liveActivityShowsMissed)
            scheduleMissedCheck(f.missedUntil)
        } else if isActive {
            // Back in the app with nothing close: drop an early one; it'll come back when it's due.
            liveActivity.end()
        }
    }

    static let missedCheckTask = "cadence.liveactivity.missed-check"

    /// The app can't touch the activity while it's suspended, so ask iOS to wake it once a missed
    /// meeting's time is up, to take it down (or switch it to "Missed"). iOS decides when, so it's
    /// best effort: the activity's stale date redraws it meanwhile.
    private func scheduleMissedCheck(_ at: Date?) {
        guard let at, at > Date(), at != scheduledMissedCheck else { return }
        scheduledMissedCheck = at
        let request = BGAppRefreshTaskRequest(identifier: Self.missedCheckTask)
        request.earliestBeginDate = at
        try? BGTaskScheduler.shared.submit(request)
    }

    @ObservationIgnored private var scheduledMissedCheck: Date?

    /// Woken in the background (see `scheduleMissedCheck`).
    func backgroundRefresh() {
        refresh()
        updateLiveActivity()
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

    // MARK: - Macs

    /// Pair a Mac (added to the end of the list), or refresh one already paired.
    func pair(_ invite: PairingInvite) { link.pair(invite) }

    /// A pairing link opened from outside the app, waiting for the user to confirm it.
    var pendingInvite: PairingInvite?

    func confirmPendingPairing() {
        guard let invite = pendingInvite else { return }
        pendingInvite = nil
        pair(invite)
    }

    /// Unpair one Mac: its saved agenda goes with it.
    func unpair(_ macID: String) { link.unpair(macID) }

    // MARK: - URLs

    /// cadence-pair://… (scanned QR or pasted link) and cadence-companion://join?id=… (Live Activity).
    @discardableResult
    func open(_ url: URL) -> Bool {
        if spotify.handle(url) { return true }
        if let invite = PairingInvite(url: url) {
            // Any web page, message or app can open a cadence-pair:// link, so one from outside the
            // app's own scanner waits for the user to say yes (see RootView).
            pendingInvite = invite
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
