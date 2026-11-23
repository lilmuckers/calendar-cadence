import AppKit
import CadenceCore
import Observation
import UserNotifications

enum AccessState { case unknown, granted, denied }

/// Root model: merges providers, applies filters, ticks once a second, drives the alert.
@MainActor
@Observable
final class AppState {
    var prefs: Preferences {
        didSet {
            guard prefs != oldValue else { return }
            if persistPrefs { prefs.save() }
            if prefs.icsFeeds != oldValue.icsFeeds { syncFeeds(fetch: true) }
            if prefs.filters != oldValue.filters || prefs.useEventColors != oldValue.useEventColors
                || prefs.localEventColors != oldValue.localEventColors
                || prefs.workSchedule != oldValue.workSchedule { recompute() }
            if prefs.inviteHorizon != oldValue.inviteHorizon || prefs.filters.disabledCalendarIDs != oldValue.filters.disabledCalendarIDs {
                Task { await refreshInvites() }
            }
            if prefs.profileRules.firefoxContainers != oldValue.profileRules.firefoxContainers {
                browsers.refresh(containers: prefs.profileRules.firefoxContainers)
            }
            onPrefsChanged?()
        }
    }

    /// The default browser and its profiles, for opening meeting links in the right one.
    @ObservationIgnored let browsers = BrowserProfileStore()

    private(set) var calendars: [CalendarInfo] = []
    private(set) var allMeetings: [Meeting] = []
    private(set) var now = Date()
    private(set) var access: AccessState = .unknown
    private(set) var lastRefresh: Date?
    private(set) var lastRemoteRefresh: Date?
    /// Filtered and de-duplicated events across every source.
    private(set) var meetings: [Meeting] = []
    /// Ids in `meetings` that come only from "agenda only" calendars.
    private(set) var agendaOnlyIDs: Set<String> = []
    /// `meetings` without agenda-only ones: what alerts, reminders, clashes, current/next and
    /// assistant timeline events run on.
    private(set) var activeMeetings: [Meeting] = []

    /// Set by the AppDelegate to show/hide windows when state changes.
    /// Fired when a meeting's alert is due. The optional style forces a presentation (used by Preview).
    @ObservationIgnored var onAlert: ((Meeting, BusyAlertStyle?) -> Void)?
    /// The user joined or snoozed a meeting here on the Mac (an alert escalation can stand down).
    @ObservationIgnored var onHandled: ((String) -> Void)?
    @ObservationIgnored var onPrefsChanged: (() -> Void)?
    /// Off while rendering screenshots so demo tweaks never touch the user's saved settings.
    @ObservationIgnored var persistPrefs = true
    @ObservationIgnored var onReminder: ((Reminder) -> Void)?
    /// Settings → Alerts → Test music fade.
    @ObservationIgnored var onTestMediaFade: (() -> Void)?
    /// Invites to show: `.daily` review, `.new` arrivals, or `.manual` from the menu or Settings.
    @ObservationIgnored var onInvites: (([Meeting], InvitePromptReason) -> Void)?
    /// Events for connected AI assistants (MCP).
    @ObservationIgnored var onEvent: ((MCPEvent) -> Void)?
    /// Open the enrichment drawer for a meeting (menu bar, countdown panel).
    @ObservationIgnored var onShowEnrichments: ((Meeting) -> Void)?
    @ObservationIgnored private var sentEvents: Set<String> = []
    @ObservationIgnored private var announcedClashes: Set<String>?
    /// Clashes found while sources are still loading after launch are taken as already known.
    @ObservationIgnored private let launchedAt = Date()
    /// A newly found clash the user hasn't decided on yet.
    @ObservationIgnored var onClash: ((Clash) -> Void)?
    /// A clash was settled or an invite answered here on the Mac (so the phone can close its pop-up).
    @ObservationIgnored var onClashResolved: ((String) -> Void)?
    @ObservationIgnored var onInviteAnswered: ((String) -> Void)?

    /// Clash key → chosen meeting id (or "all"). Persisted so a decision sticks across refreshes.
    private(set) var clashChoices: [String: String] = UserDefaults.standard.dictionary(forKey: "Cadence.clashChoices") as? [String: String] ?? [:]
    private(set) var clashes: [Clash] = []
    /// Unanswered invitations within the chosen horizon, soonest first.
    private(set) var invites: [Meeting] = []
    /// Ids of every invite we've already told the user about (nil until the first fetch).
    @ObservationIgnored private var knownInvites: Set<String>? =
        (UserDefaults.standard.array(forKey: "Cadence.knownInvites") as? [String]).map(Set.init)
    @ObservationIgnored private var rawInvites: [Meeting] = []
    /// Replies sent this session, so a stale fetch doesn't resurrect them.
    @ObservationIgnored private var answered: Set<String> = []
    /// Clashes already put to the user (answered or "decide later"), so a relaunch doesn't ask again.
    @ObservationIgnored private var promptedClashes: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "Cadence.promptedClashes") ?? [])
    /// Clash key → when its last meeting ends. Saved choices and prompts are forgotten after that,
    /// not when a clash is briefly missing (sources still loading after launch).
    @ObservationIgnored private var clashExpiry: [String: Date] =
        (UserDefaults.standard.dictionary(forKey: "Cadence.clashExpiry") as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
    /// False until every source has delivered once after launch; clash prompts wait for it, since a
    /// half-loaded agenda gives clashes different keys (another copy of a meeting wins de-duplication).
    @ObservationIgnored private var sourcesSettled = false
    @ObservationIgnored private var sentReminders: Set<String> = []
    @ObservationIgnored private var travelTimes: [String: (eta: TimeInterval, at: Date)] = [:]
    @ObservationIgnored private var travelInFlight: Set<String> = []
    @ObservationIgnored private var travelFailures: [String: Date] = [:]

    /// Link to a paired iPhone. Observable on its own, so views can watch `companion.phoneDisplaying`.
    @ObservationIgnored let companion = CompanionHub()
    /// Updates from GitHub releases. Observable on its own, like `companion`.
    @ObservationIgnored let updater = Updater()
    /// What assistants attached to meetings. Observable on its own, like `companion`.
    @ObservationIgnored let enrichments = EnrichmentStore()
    @ObservationIgnored private let eventKit = EventKitProvider()
    @ObservationIgnored let googleAuth = GoogleAuth()
    @ObservationIgnored let microsoftAuth = MicrosoftAuth()
    @ObservationIgnored let slackAuth = SlackAuth()
    @ObservationIgnored lazy var lateMessenger = LateMessenger(google: googleAuth, microsoft: microsoftAuth, slack: slackAuth)
    /// "Running late" messages sent, by meeting id: when you said you'd be there.
    private(set) var lateNotices: [String: LateNotice] = [:]
    /// One provider per signed-in Microsoft account.
    private(set) var microsoftProviders: [MicrosoftCalendarProvider] = []
    /// One provider per signed-in Google account.
    private(set) var googleProviders: [GoogleCalendarProvider] = []
    private(set) var icsProviders: [ICSProvider] = []
    @ObservationIgnored private var providers: [CalendarProvider] { [eventKit] + googleProviders + microsoftProviders + icsProviders }
    @ObservationIgnored private var planner = AlertPlanner()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        prefs = Preferences.load()
        browsers.refresh(containers: prefs.profileRules.firefoxContainers)
    }

    // MARK: - Lifecycle

    func start() {
        eventKit.onChange = { [weak self] in
            self?.refresh()
            Task { await self?.refreshInvites() }
        }
        syncGoogle(fetch: false)
        syncMicrosoft(fetch: false)
        syncFeeds(fetch: false)
        Task {
            // Before setup, leave the macOS prompt for the calendars step, which says why first.
            if prefs.setupDone || !eventKit.isUndetermined { await requestAccess() } else { refresh() }
            await refreshRemote()
            sourcesSettled = true
            recompute()
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                Task { await self?.refreshRemote() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = false }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    func requestAccess() async {
        let granted = await eventKit.requestAccess()
        access = granted ? .granted : .denied
        refresh()
    }

    // MARK: - Setup

    /// Whether macOS lets Cadence post notifications; nil until known or while it hasn't asked yet.
    private(set) var notificationsAllowed: Bool?
    /// Settings → General → Run setup again.
    @ObservationIgnored var onRunSetup: (() -> Void)?
    /// The Settings tab to show next time Settings opens (setup's "When you're ready" rows).
    var settingsTab: SettingsTab = .general

    /// macOS Calendar access hasn't been asked for yet.
    var calendarAccessUndetermined: Bool { access != .granted && eventKit.isUndetermined }

    /// Skipped setup steps still open, for the menu's checklist. Empty until setup has run once.
    var setupTasks: [SetupTask] {
        guard prefs.setupDone, !prefs.setupChecklistDismissed, lastRemoteRefresh != nil else { return [] }
        return SetupTask.open(hasCalendars: !calendars.isEmpty, notificationsAllowed: notificationsAllowed)
    }

    func refreshNotificationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral: notificationsAllowed = true
        case .denied: notificationsAllowed = false
        default: notificationsAllowed = prefs.setupDone ? false : nil
        }
    }

    /// Ask macOS for notifications (once; after a "Don't Allow" it opens System Settings instead).
    func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .denied {
            openNotificationSettings()
        } else {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshNotificationStatus()
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The setup preset the alert settings match, nil once tuned by hand.
    var alertPreset: AlertPreset? {
        get { AlertPreset.matching(prefs.alertSettings) }
        set { if let newValue { prefs.alertSettings = newValue.settings } }
    }

    /// A sample alert for setup's "Show me an alert": always a made-up meeting, so Join opens nothing real.
    func previewSetupAlert(_ preset: AlertPreset) {
        let lead = preset.takesOverScreen ? preset.settings.takeoverLeadSeconds : TimeInterval(preset.settings.headsUpMinutes * 60)
        let start = Date().addingTimeInterval(lead)
        let sample = Meeting(
            id: "preview-setup",
            title: "Design Review",
            start: start,
            end: start.addingTimeInterval(1800),
            calendar: CalendarInfo(id: "preview", title: "Work", sourceTitle: "Preview",
                                   color: RGBAColor(red: 0.35, green: 0.45, blue: 1)),
            attendeeCount: 6,
            joinLink: MeetingLink(service: .zoom, url: URL(string: "https://example.com/cadence-preview")!)
        )
        onAlert?(sample, preset.takesOverScreen ? .fullScreen : .notification)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.date(byAdding: .day, value: 2, to: from) ?? from.addingTimeInterval(172_800)
        calendars = providers.flatMap { $0.calendars() }
        allMeetings = providers
            .flatMap { $0.meetings(from: from, to: to) }
            .sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
        planner.prune(keeping: allMeetings)
        enrichments.prune()
        lastRefresh = Date()
        recompute()
    }

    private func recompute() {
        let previous = activeMeetings
        let previousAll = meetings
        applyVisible()
        companion.pushSnapshot()
        clashes = detectClashes(after: Date())
        emitChanges(from: previous, all: previousAll)
        saveClashMemory()
        if prefs.clashPromptEnabled, sourcesSettled,
           let fresh = clashes.first(where: { clashChoices[$0.key] == nil && !promptedClashes.contains($0.key) }) {
            promptedClashes.insert(fresh.key)
            saveClashMemory()
            onClash?(fresh)
        }
    }

    static let agendaURIs = ["cadence://agenda/today", "cadence://agenda/tomorrow", "cadence://next", "cadence://clashes"]

    /// Tell assistants about moved/cancelled meetings and new clashes, and refresh their resources.
    private func emitChanges(from previous: [Meeting], all previousAll: [Meeting]) {
        guard let onEvent else { return }
        let now = Date()
        if previousAll != meetings {
            onEvent(MCPEvent(type: "agenda.updated", message: "Agenda updated", uris: Self.agendaURIs, log: false))
        }
        if !previous.isEmpty {
            for change in MeetingChangeDetector.changes(old: previous, new: activeMeetings, now: now) {
                switch change {
                case .moved(let from, let to):
                    onEvent(MCPEvent(type: "meeting.changed", message: "\(to.title) moved to \(Theme.dayTime(to.start))",
                                     data: ["meeting": dto(to), "previous_start": .string(MeetingDTO.format(from.start)),
                                            "previous_end": .string(MeetingDTO.format(from.end))],
                                     uris: Self.agendaURIs))
                case .canceled(let m):
                    onEvent(MCPEvent(type: "meeting.canceled", message: "\(m.title) was cancelled", data: ["meeting": dto(m)],
                                     uris: Self.agendaURIs, level: "notice"))
                }
            }
        }
        let keys = Set(clashes.map(\.key))
        if let announced = announcedClashes, Date().timeIntervalSince(launchedAt) > 60 {
            for clash in clashes where !announced.contains(clash.key) {
                onEvent(MCPEvent(type: "clash.new", message: "Double-booked: " + clash.meetings.map(\.title).joined(separator: " / "),
                                 data: ["meetings": .array(clash.meetings.map(dto))], uris: ["cadence://clashes"], level: "warning"))
            }
        }
        announcedClashes = (announcedClashes ?? []).union(keys)
    }

    /// Meeting as JSON for assistants, with Cadence's own flags.
    func dto(_ m: Meeting) -> JSONValue {
        let inClash = clashes.contains { $0.meetings.contains { $0.id == m.id } }
        let value = MeetingDTO(m, now: Date(), inClash: inClash, mutedByClash: suppressedByClash.contains(m.id),
                               hiddenFromPanel: isHiddenFromPanel(m), agendaOnly: isAgendaOnly(m),
                               enrichmentCount: enrichments.enrichments(for: m).count)
        var json = (try? JSONValue(encoding: value)) ?? .null
        let conflicts = prefs.workSchedule.conflicts(for: m).map(\.label)
        if !conflicts.isEmpty, case .object(var o) = json {
            o["work_schedule"] = .array(conflicts.map { .string($0) })
            json = .object(o)
        }
        return json
    }

    private func checkTimelineEvents() {
        guard let onEvent else { return }
        let due = MCPEventPlanner.due(activeMeetings, now: now, sent: sentEvents,
                                      leadMinutes: max(1, prefs.headsUpMinutes), wrapMinutes: prefs.wrapUpMinutes)
        for d in due {
            sentEvents.insert(d.key)
            onEvent(MCPEvent(type: d.type, message: MCPEventPlanner.message(d, now: now), data: ["meeting": dto(d.meeting)],
                             uris: ["cadence://next", "cadence://agenda/today", "cadence://status"]))
        }
    }

    private func applyVisible() {
        var shown = allMeetings.filter { prefs.filters.allows($0) }
        if !prefs.useEventColors { shown = shown.map { var m = $0; m.eventColor = nil; return m } }
        shown = shown.map(applyLocalColor)
        if !pendingColors.isEmpty {
            shown = shown.map { m in
                guard let p = pendingColors[colorKey(m)] else { return m }
                var m = m
                m.eventColor = p.color
                return m
            }
        }
        meetings = MeetingDeduplicator.dedupe(shown)
        agendaOnlyIDs = prefs.filters.agendaOnlyIDs(in: meetings, sources: shown)
        activeMeetings = agendaOnlyIDs.isEmpty ? meetings : meetings.filter { !agendaOnlyIDs.contains($0.id) }
    }

    func isAgendaOnly(_ m: Meeting) -> Bool { agendaOnlyIDs.contains(m.id) }

    func isCalendarAgendaOnly(_ id: String) -> Bool { prefs.filters.agendaOnlyCalendarIDs.contains(id) }

    func setCalendar(_ id: String, agendaOnly: Bool) {
        if agendaOnly { prefs.filters.agendaOnlyCalendarIDs.insert(id) } else { prefs.filters.agendaOnlyCalendarIDs.remove(id) }
    }

    private func applyLocalColor(_ m: Meeting) -> Meeting {
        guard let id = prefs.localEventColors[colorKey(m)], let choice = EventColorChoice.choice(id: id) else { return m }
        var m = m
        m.eventColor = choice.color
        return m
    }

    private func colorKey(_ m: Meeting) -> String { m.recurs ? m.seriesID : m.id }

    // MARK: - Invites

    /// Re-read unanswered invites from every source, and announce ones we haven't seen.
    func refreshInvites() async {
        let until = prefs.inviteHorizon.end(from: Date())
        var raw: [Meeting] = []
        for provider in providers { raw += await provider.fetchInvites(until: until) }
        rawInvites = raw
        rebuildInvites(announce: true)
    }

    private func rebuildInvites(announce: Bool) {
        let enabled = rawInvites.filter { isCalendarEnabled($0.calendar.id) && !answered.contains($0.seriesID) }
            .map(applyLocalColor)
        let merged = InvitePlanner.merge(enabled) { [unowned self] in canRespond($0) }
        invites = InvitePlanner.pending(merged, now: Date(), horizon: prefs.inviteHorizon)

        let fresh = InvitePlanner.newInvites(invites, known: knownInvites)
        if let onEvent {
            for m in fresh {
                onEvent(MCPEvent(type: "invite.new", message: "New invite: \(m.title), \(Theme.dayTime(m.start))",
                                 data: ["meeting": dto(m)], uris: ["cadence://invites"]))
            }
            onEvent(MCPEvent(type: "invites.updated", message: "Invites updated", uris: ["cadence://invites"], log: false))
        }
        knownInvites = (knownInvites ?? []).union(invites.map(\.seriesID))
        UserDefaults.standard.set(Array(knownInvites ?? []), forKey: "Cadence.knownInvites")
        if announce, !fresh.isEmpty, prefs.newInviteAlert != .off { onInvites?(fresh, .new) }
    }

    func reviewInvites() { onInvites?(invites, .manual) }

    func provider(for meeting: Meeting) -> CalendarProvider? { providers.first { $0.owns(meeting) } }

    /// The copy of `meeting` (it may have been merged with others) that a source can act on.
    private func actionable(_ meeting: Meeting, _ test: (CalendarProvider, Meeting) -> Bool) -> (CalendarProvider, Meeting)? {
        let candidates = [meeting] + (rawInvites + allMeetings).filter {
            $0.id != meeting.id && (MeetingDeduplicator.isSameMeeting($0, meeting) || $0.seriesID == meeting.seriesID)
        }
        for m in candidates {
            if let p = provider(for: m), test(p, m) { return (p, m) }
        }
        return nil
    }

    func canRespond(_ meeting: Meeting) -> Bool { demoMode || actionable(meeting) { $0.canRespond($1) } != nil }

    /// Screenshot rendering: pretend every invite can be answered.
    @ObservationIgnored var demoMode = false

    /// Send an RSVP. Sources that can't (macOS Calendar) open the event in Calendar instead.
    func respond(_ meeting: Meeting, _ reply: RSVP) async throws {
        guard let (provider, target) = actionable(meeting, { $0.canRespond($1) }) else {
            openInCalendar(meeting)
            return
        }
        try await track(meeting.id) { try await provider.respond(target, reply) }
        onInviteAnswered?(meeting.id)
        answered.insert(meeting.seriesID)
        allMeetings = allMeetings.map { m in
            guard m.seriesID == meeting.seriesID || MeetingDeduplicator.isSameMeeting(m, meeting) else { return m }
            var m = m
            m.participation = reply.participation
            return m
        }
        recompute()
        rebuildInvites(announce: false)
    }

    /// Colour an event: stored in Google when possible, otherwise kept by Cadence. nil = back to the calendar colour.
    /// The new colour shows at once while the source saves it; it snaps back if the save fails.
    func setColor(_ meeting: Meeting, _ choice: EventColorChoice?) async throws {
        let key = colorKey(meeting)
        pendingColors[key] = PendingColor(color: choice?.color)
        recompute()
        defer {
            pendingColors[key] = nil
            recompute()
        }
        try await track(meeting.id) {
            if let (provider, target) = actionable(meeting, { $0.canSetColor($1) }) {
                try await provider.setColor(target, choice)
                prefs.localEventColors[key] = nil
            } else {
                prefs.localEventColors[key] = choice?.id
            }
        }
        rebuildInvites(announce: false)
    }

    /// The colours offered for `meeting`, named as its calendar names them (Google colour labels).
    /// `all` ignores the "named colours only" preference (assistants can still use any colour).
    func colorChoices(for meeting: Meeting, all: Bool = false) -> [EventColorChoice] {
        if let (provider, target) = actionable(meeting, { $0.canSetColor($1) }), let choices = provider.colorChoices(for: target) {
            guard prefs.namedColorsOnly, !all else { return choices }
            return EventColorChoice.namedOnly(choices, keeping: currentColor(of: meeting, in: choices)?.id)
        }
        return EventColorChoice.palette
    }

    /// The choice matching `meeting`'s current colour, if any.
    func currentColor(of meeting: Meeting, in choices: [EventColorChoice]) -> EventColorChoice? {
        meeting.eventColor.flatMap { c in choices.first { $0.color == c } }
    }

    // MARK: - Save feedback

    enum SaveState: Equatable { case saving, saved }

    /// Meeting id → a reply or colour change being saved, or just saved (for the "done" flash).
    private(set) var saveStates: [String: SaveState] = [:]
    /// Colour key → the colour being saved, shown before the source confirms it.
    private var pendingColors: [String: PendingColor] = [:]
    private struct PendingColor { var color: RGBAColor? }

    /// Runs a save for `id`, marking it saving, then briefly saved.
    func track(_ id: String, _ work: () async throws -> Void) async throws {
        saveStates[id] = .saving
        do {
            try await work()
        } catch {
            saveStates[id] = nil
            throw error
        }
        saveStates[id] = .saved
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            if self?.saveStates[id] == .saved { self?.saveStates[id] = nil }
        }
    }

    func wantsColorPrompt(_ meeting: Meeting) -> Bool { prefs.colorPromptCalendarIDs.contains(meeting.calendar.id) }

    private func checkDailyReview() {
        guard prefs.inviteReviewDaily, !invites.isEmpty else { return }
        let cal = Calendar.current
        guard let at = cal.date(bySettingHour: prefs.summaryTime / 60, minute: prefs.summaryTime % 60, second: 0, of: now),
              now >= at, now.timeIntervalSince(at) < 4 * 3600 else { return }
        let key = "review:\(Int(cal.startOfDay(for: now).timeIntervalSince1970))"
        guard UserDefaults.standard.string(forKey: "Cadence.lastInviteReview") != key else { return }
        UserDefaults.standard.set(key, forKey: "Cadence.lastInviteReview")
        onInvites?(invites, .daily)
    }

    /// Records when each live clash ends, drops choices and prompts for clashes that are over, and saves.
    private func saveClashMemory(now: Date = Date()) {
        for clash in clashes {
            if let end = clash.meetings.map(\.end).max() { clashExpiry[clash.key] = end }
        }
        // Entries saved before expiry was tracked get a couple of days.
        for key in Set(clashChoices.keys).union(promptedClashes) where clashExpiry[key] == nil {
            clashExpiry[key] = now.addingTimeInterval(2 * 86_400)
        }
        let expired = Set(clashExpiry.filter { $0.value < now }.keys)
        clashExpiry = clashExpiry.filter { !expired.contains($0.key) }
        clashChoices = clashChoices.filter { !expired.contains($0.key) }
        promptedClashes.subtract(expired)
        let known = Set(clashChoices.keys).union(promptedClashes)
        clashExpiry = clashExpiry.filter { known.contains($0.key) }
        let d = UserDefaults.standard
        d.set(clashChoices, forKey: "Cadence.clashChoices")
        d.set(Array(promptedClashes).sorted(), forKey: "Cadence.promptedClashes")
        d.set(clashExpiry.mapValues(\.timeIntervalSince1970), forKey: "Cadence.clashExpiry")
    }

    func resolveClash(_ clash: Clash, choice: String?) {
        // nil = "decide later": alerts fire for everything, and we won't ask again for this clash.
        guard let choice else { return }
        clashChoices[clash.key] = choice
        UserDefaults.standard.set(clashChoices, forKey: "Cadence.clashChoices")
        onClashResolved?(clash.key)
    }

    /// Clashes `meeting` is part of.
    func clashes(involving meeting: Meeting) -> [Clash] {
        clashes.filter { $0.meetings.contains { $0.id == meeting.id } }
    }

    /// The saved choice for a clash: a meeting id, "all", or nil (not decided).
    func clashChoice(_ clash: Clash) -> String? { clashChoices[clash.key] }

    /// Forgets the choice and shows the clash prompt again now.
    func askAgain(_ clash: Clash) {
        clashChoices[clash.key] = nil
        promptedClashes.insert(clash.key)
        saveClashMemory()
        onClash?(clash)
    }

    /// Forgets every clash choice; the prompt asks again for each current clash.
    func resetClashChoices() {
        clashChoices = [:]
        promptedClashes = []
        saveClashMemory()
        recompute()
    }

    /// Breaks from the work schedule for the days Cadence loads (today and tomorrow), as stand-in meetings.
    var breakMeetings: [Meeting] {
        let from = Calendar.current.startOfDay(for: Date())
        return prefs.workSchedule.breakMeetings(from: from, to: from.addingTimeInterval(2 * 86_400))
    }

    /// Double-bookings, plus meetings booked over a break when the schedule defends breaks that way.
    private func detectClashes(after now: Date) -> [Clash] {
        var pool = activeMeetings
        if prefs.workSchedule.enabled && prefs.workSchedule.defences.clashPrompt {
            pool = (pool + breakMeetings).sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
        }
        return ClashDetector.clashes(in: pool, after: now)
    }

    /// How a meeting sits against working hours and breaks, worded for an invite.
    func workConflicts(_ m: Meeting) -> [String] {
        guard prefs.workSchedule.defences.flagInvites else { return [] }
        return prefs.workSchedule.conflicts(for: m).map(\.label)
    }

    /// Meetings the user chose not to be alerted for because of a clash.
    var suppressedByClash: Set<String> { ClashDetector.suppressed(clashes: clashes, choices: clashChoices) }

    /// Replace live data with fixed demo meetings (used by the screenshot renderer).
    func loadDemo(_ demo: [Meeting], calendars: [CalendarInfo], now: Date) {
        timer?.invalidate()
        self.now = now
        self.calendars = calendars
        access = .granted
        allMeetings = demo.sorted { $0.start < $1.start }
        applyVisible()
        clashes = detectClashes(after: now)
    }

    // MARK: - Hotkey

    /// What the global "join" shortcut opens: a meeting starting within 10 minutes beats one that's
    /// already running; otherwise the live meeting; otherwise the next one today with a link.
    var joinTarget: Meeting? {
        let linked = activeMeetings.filter { !$0.isAllDay && $0.joinLink != nil && $0.end > now && !suppressedByClash.contains($0.id) }
        if let soon = linked.first(where: { $0.start > now && $0.start.timeIntervalSince(now) <= 600 }) { return soon }
        if let live = linked.last(where: { $0.isInProgress(at: now) }) { return live }
        return linked.first { Calendar.current.isDate($0.start, inSameDayAs: now) }
    }

    func joinFromHotKey() {
        guard let target = joinTarget else { NSSound.beep(); return }
        join(target)
    }

    // MARK: - Reminders

    private func checkReminders() {
        var reminders: [Reminder] = []
        let upcoming = activeMeetings.filter { !$0.isAllDay && $0.start > now && !suppressedByClash.contains($0.id) }
        if prefs.headsUpEnabled {
            reminders += ReminderPlanner.headsUps(for: upcoming, minutes: prefs.headsUpMinutes)
        }
        if prefs.leaveEnabled && !prefs.leaveOffsets.isEmpty {
            for m in upcoming where m.physicalLocation != nil && m.start.timeIntervalSince(now) < 4 * 3600 {
                if let travel = travelTimes[m.id] {
                    reminders += ReminderPlanner.leaves(for: m, travel: travel.eta, offsets: prefs.leaveOffsets)
                    if now.timeIntervalSince(travel.at) > 900 { updateTravel(m) }
                } else {
                    updateTravel(m)
                }
            }
        }
        if prefs.wrapUpEnabled {
            let live = current.filter { $0.participation != .declined && !suppressedByClash.contains($0.id) }
            reminders += ReminderPlanner.wrapUps(live: live, all: activeMeetings, minutes: prefs.wrapUpMinutes,
                                                 onlyBackToBack: prefs.wrapUpOnlyBackToBack)
        }
        let schedule = prefs.workSchedule
        if schedule.enabled && (schedule.defences.breakNudge || schedule.defences.overrunWarning) {
            let breaks = breakMeetings.filter { $0.end > now && !suppressedByClash.contains($0.id) }
            let live = current.filter { !suppressedByClash.contains($0.id) }
            reminders += ReminderPlanner.breakNudges(breaks: breaks, meetings: live,
                                                     nudge: schedule.defences.breakNudge, overrun: schedule.defences.overrunWarning)
        }
        if schedule.enabled && prefs.dayWrapNotification, canShowAgenda, lastRefresh != nil,
           let wrap = ReminderPlanner.dayWrap(meetings: activeMeetings.filter { !suppressedByClash.contains($0.id) },
                                              schedule: schedule, now: now) {
            reminders.append(wrap)
        }
        if prefs.summaryEnabled, canShowAgenda, lastRefresh != nil,
           let summary = ReminderPlanner.morningSummary(meetings: activeMeetings, now: now,
                                                        hour: prefs.summaryTime / 60, minute: prefs.summaryTime % 60),
           UserDefaults.standard.string(forKey: "Cadence.lastSummary") != summary.key {
            reminders.append(summary)
        }
        // Checked only when a call-dependent reminder is due. Not marked sent when skipped, so if the
        // call starts again within the reminder's grace period it still goes out.
        var onCall: Bool?
        for r in ReminderPlanner.due(reminders, now: now, sent: sentReminders) {
            if r.needsActiveCall {
                if onCall == nil { onCall = SystemContext.microphoneApp() != nil }
                if onCall == false { continue }
            }
            sentReminders.insert(r.key)
            if r.isSummary { UserDefaults.standard.set(r.key, forKey: "Cadence.lastSummary") }
            onReminder?(r)
        }
    }

    /// Re-estimate travel time (traffic changes), at most every 15 minutes per meeting.
    private func updateTravel(_ m: Meeting) {
        guard let place = m.physicalLocation, !travelInFlight.contains(m.id) else { return }
        // Back off for 15 minutes after a failed lookup so we don't hammer MapKit.
        if let failed = travelFailures[m.id], Date().timeIntervalSince(failed) < 900 { return }
        travelInFlight.insert(m.id)
        let mode = prefs.travelMode
        Task {
            defer { travelInFlight.remove(m.id) }
            guard let item = await TravelEstimator.shared.place(for: place),
                  let eta = await TravelEstimator.shared.eta(to: item, mode: mode, departing: Date()) else {
                travelFailures[m.id] = Date()
                return
            }
            travelTimes[m.id] = (eta, Date())
        }
    }

    /// Fetch every network source (ICS feeds, Google), then rebuild.
    func refreshRemote() async {
        lastRemoteRefresh = Date()
        await withTaskGroup(of: Void.self) { group in
            for provider in providers { group.addTask { await provider.refreshRemote() } }
        }
        refresh()
        await refreshInvites()
    }

    /// Keep one ICSProvider per enabled feed, reusing unchanged ones so their cache survives.
    private func syncFeeds(fetch: Bool) {
        let enabled = prefs.icsFeeds.filter(\.enabled)
        var next: [ICSProvider] = []
        var fresh: [ICSProvider] = []
        for feed in enabled {
            if let existing = icsProviders.first(where: { $0.feed == feed }) {
                next.append(existing)
            } else {
                let provider = ICSProvider(feed: feed)
                provider.onChange = { [weak self] in self?.refresh() }
                next.append(provider)
                fresh.append(provider)
            }
        }
        icsProviders = next
        refresh()
        if fetch { for p in fresh { Task { await p.refreshRemote() } } }
    }

    /// Keep one provider per Google account, reusing existing ones so their cache survives.
    private func syncGoogle(fetch: Bool) {
        var next: [GoogleCalendarProvider] = []
        var fresh: [GoogleCalendarProvider] = []
        for account in googleAuth.accounts {
            if let existing = googleProviders.first(where: { $0.accountID == account.id }) {
                next.append(existing)
            } else {
                let provider = GoogleCalendarProvider(accountID: account.id, auth: googleAuth)
                provider.onChange = { [weak self] in self?.refresh() }
                next.append(provider)
                fresh.append(provider)
            }
        }
        googleProviders = next
        refresh()
        if fetch { for p in fresh { Task { await p.refreshRemote() } } }
    }

    /// Keep one provider per Microsoft account, reusing existing ones so their cache survives.
    private func syncMicrosoft(fetch: Bool) {
        var next: [MicrosoftCalendarProvider] = []
        var fresh: [MicrosoftCalendarProvider] = []
        for account in microsoftAuth.accounts {
            if let existing = microsoftProviders.first(where: { $0.accountID == account.id }) {
                next.append(existing)
            } else {
                let provider = MicrosoftCalendarProvider(accountID: account.id, auth: microsoftAuth)
                provider.onChange = { [weak self] in self?.refresh() }
                next.append(provider)
                fresh.append(provider)
            }
        }
        microsoftProviders = next
        refresh()
        if fetch { for p in fresh { Task { await p.refreshRemote() } } }
    }

    func microsoftSignIn() async throws {
        let account = try await microsoftAuth.signIn()
        syncMicrosoft(fetch: false)
        await microsoftProviders.first { $0.accountID == account.id }?.refreshRemote()
        await refreshInvites()
    }

    func microsoftSignOut(_ account: MicrosoftAccount) {
        microsoftAuth.signOut(account)
        prefs.filters.disabledCalendarIDs = prefs.filters.disabledCalendarIDs.filter { !$0.hasPrefix("msft:\(account.id):") }
        syncMicrosoft(fetch: false)
    }

    func microsoftUseBuiltInClient() {
        microsoftAuth.clearCustomClient()
        syncMicrosoft(fetch: false)
    }

    var hasRemoteSources: Bool { !googleProviders.isEmpty || !microsoftProviders.isEmpty || !icsProviders.isEmpty }
    var canShowAgenda: Bool { access == .granted || hasRemoteSources }

    /// Adds a Google account (or reconnects one, if the user picks an account that's already listed).
    func googleSignIn() async throws {
        let account = try await googleAuth.signIn()
        syncGoogle(fetch: false)
        await googleProviders.first { $0.accountID == account.id }?.refreshRemote()
        await refreshInvites()
    }

    func googleSignOut(_ account: GoogleAccount) {
        googleAuth.signOut(account)
        prefs.filters.disabledCalendarIDs = prefs.filters.disabledCalendarIDs.filter { !$0.hasPrefix("gcal:\(account.id):") }
        syncGoogle(fetch: false)
    }

    func googleUseBuiltInClient() {
        googleAuth.clearCustomCredentials()
        syncGoogle(fetch: false)
    }

    private func tick() {
        // While a menu is open, don't touch observed state: SwiftUI would rebuild the open
        // context menu every second, which collapses submenus. Alerts catch up once it closes.
        guard !menuOpen else { return }
        now = Date()
        // Belt and braces: EventKit notifies on change, but refetch every 5 minutes anyway.
        if let last = lastRefresh, now.timeIntervalSince(last) > 300 { refresh() }
        if let last = lastRemoteRefresh, now.timeIntervalSince(last) > 600 { Task { await refreshRemote() } }
        checkAlert()
        if Int(now.timeIntervalSince1970) % 5 == 0 {
            checkReminders()
            checkTimelineEvents()
            checkDailyReview()
        }
    }

    // MARK: - Derived

    var todayMeetings: [Meeting] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return meetings.filter { $0.end > start && $0.start < end }
    }

    /// Tomorrow's meetings, shown under today's in the evening or once today is done.
    var tomorrowMeetings: [Meeting] {
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)),
              let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return meetings.filter { $0.end > start && $0.start < end }
    }

    var showsTomorrow: Bool {
        guard prefs.tomorrowPreview, !tomorrowMeetings.isEmpty else { return false }
        let doneToday = !todayMeetings.contains { !$0.isAllDay && $0.end > now && !isAgendaOnly($0) }
        return doneToday || Calendar.current.component(.hour, from: now) >= prefs.tomorrowFromHour
    }

    /// Timed meetings happening right now.
    var current: [Meeting] { activeMeetings.filter { !$0.isAllDay && $0.isInProgress(at: now) } }

    /// The next timed meeting that has not started yet.
    var next: Meeting? { activeMeetings.first { !$0.isAllDay && $0.start > now } }

    var isNextToday: Bool {
        guard let next else { return false }
        return Calendar.current.isDate(next.start, inSameDayAs: now)
    }

    // MARK: - Alerts

    private func checkAlert() {
        guard prefs.takeoverEnabled else { return }
        let suppressed = suppressedByClash
        let candidates = activeMeetings.filter {
            (!prefs.takeoverOnlyWithLink || $0.joinLink != nil) && !suppressed.contains($0.id)
        }
        guard let due = planner.due(in: candidates, now: now, leadTime: prefs.takeoverLeadSeconds) else { return }
        planner.markFired(due)
        onAlert?(due, nil)
    }

    // MARK: - Running late

    struct LateNotice: Equatable {
        var text: String
        var via: String
        var sentAt: Date
        /// When you said you'd be there.
        var promised: Date
    }

    struct LateDraft {
        var situation: LateSituation
        /// Messages on offer, the suggestion first.
        var messages: [String]
        /// Where it could go, best guess first.
        var channels: [LateOption]
    }

    /// The suggested messages for `meeting` (suggestion first) and where they could go (best guess first).
    func lateDraft(for meeting: Meeting, minutes: Int) -> LateDraft {
        let previous = RunningLate.previous(to: meeting, in: activeMeetings)
        let situation = RunningLate.situation(previous: previous, now: Date(), onCall: SystemContext.microphoneApp() != nil)
        let mine = lateMessenger.myEmails
        return LateDraft(
            situation: situation,
            messages: RunningLate.options(situation, previous: previous, minutes: minutes, settings: prefs.lateMessages, myEmails: mine),
            channels: lateMessenger.options(for: meeting, rules: prefs.lateMessages.domainRules,
                                            preferredAccountIDs: messagingAccountIDs(for: meeting))
        )
    }

    /// The accounts a meeting is "for", best first: the one matching its browser profile (so a client's
    /// meetings are answered from that client's account), then the account its calendar belongs to.
    func messagingAccountIDs(for meeting: Meeting) -> [String] {
        var ids: [String] = []
        func add(email: String?) {
            guard let email = email?.lowercased(), !email.isEmpty else { return }
            ids += googleAuth.accounts.filter { $0.email?.lowercased() == email }.map(\.id)
            ids += microsoftAuth.accounts.filter { $0.email?.lowercased() == email }.map(\.id)
        }
        add(email: profileChoice(for: meeting)?.profile.email)
        let cal = meeting.calendar.id
        ids += googleAuth.accounts.filter { cal.hasPrefix("gcal:\($0.id):") }.map(\.id)
        ids += microsoftAuth.accounts.filter { cal.hasPrefix("msft:\($0.id):") }.map(\.id)
        // macOS Calendar accounts are usually named after their address.
        let source = meeting.calendar.sourceTitle.lowercased()
        for a in googleAuth.accounts where a.email.map({ source.contains($0.lowercased()) }) == true { ids.append(a.id) }
        for a in microsoftAuth.accounts where a.email.map({ source.contains($0.lowercased()) }) == true { ids.append(a.id) }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    var canSendLateMessages: Bool { prefs.lateMessages.enabled && lateMessenger.isSetUp }

    /// Sends the message as you, exactly where chosen, then holds the alert off until you said you'd be there.
    func sendLateMessage(_ text: String, minutes: Int, via option: LateOption, for meeting: Meeting) async throws {
        try await lateMessenger.send(text, via: option, meeting: meeting)
        let promised = max(Date(), meeting.start).addingTimeInterval(TimeInterval(minutes * 60))
        lateNotices[meeting.id] = LateNotice(text: text, via: "\(option.label) (\(option.accountLabel))", sentAt: Date(), promised: promised)
        snooze(meeting, seconds: promised.timeIntervalSinceNow)
    }

    /// A notification saying whether a running-late message sent from a menu went out.
    func notifyLateOutcome(_ error: Error?, option: LateOption, meeting: Meeting) {
        let content = UNMutableNotificationContent()
        content.title = error == nil ? "Told \(meeting.title) you're running late" : "Couldn't send your running-late message"
        content.body = error.map(LateMessenger.short) ?? "Sent via \(option.label) from \(option.accountLabel)."
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(UNNotificationRequest(identifier: "late:\(meeting.id)", content: content, trigger: nil))
        }
    }

    /// How late you are for the alert's purposes: counted from when you said you'd be there, once you've
    /// sent a running-late message, so it calms down and only gets cross again if you miss that too.
    func lateClockStart(for meeting: Meeting) -> Date {
        max(meeting.start, lateNotices[meeting.id]?.promised ?? meeting.start)
    }

    func snooze(_ meeting: Meeting, seconds: TimeInterval = 60) {
        planner.snooze(meeting, until: Date().addingTimeInterval(seconds))
        onHandled?(meeting.id)
    }

    /// Fire an alert now for the next meeting (Settings → Alerts → Preview).
    /// With no style, it is routed exactly as a real alert would be right now.
    func previewAlert(style: BusyAlertStyle? = nil) {
        let sample = next ?? Meeting(
            id: "preview",
            title: "Design Review",
            start: Date().addingTimeInterval(prefs.takeoverLeadSeconds),
            end: Date().addingTimeInterval(prefs.takeoverLeadSeconds + 1800),
            calendar: CalendarInfo(id: "preview", title: "Work", sourceTitle: "Preview",
                                   color: RGBAColor(red: 0.35, green: 0.45, blue: 1)),
            location: "1 Infinite Loop, Cupertino, CA",
            attendeeCount: 6,
            joinLink: MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/123456789")!)
        )
        onAlert?(sample, style)
    }

    /// A full-screen alert for a made-up meeting that started `lateBy` seconds ago, to show the panic ramp.
    /// Always uses demo data, so Join can never open a real meeting.
    func previewLateAlert(lateBy: TimeInterval = 60) {
        let start = Date().addingTimeInterval(-lateBy)
        let sample = Meeting(
            id: "preview-late",
            title: "Design Review",
            start: start,
            end: start.addingTimeInterval(1800),
            calendar: CalendarInfo(id: "preview", title: "Work", sourceTitle: "Preview",
                                   color: RGBAColor(red: 0.35, green: 0.45, blue: 1)),
            attendeeCount: 6,
            joinLink: MeetingLink(service: .zoom, url: URL(string: "https://example.com/cadence-preview")!)
        )
        onAlert?(sample, .fullScreen)
    }

    // MARK: - Actions

    /// The profile `meeting` would open in, if any rule applies to the default browser's profiles.
    func profileChoice(for meeting: Meeting) -> ProfileChoice? {
        ProfileResolver.resolve(meeting, rules: prefs.profileRules, profiles: browsers.profiles)
    }

    /// Where Join would send `meeting` right now.
    func joinRoute(for meeting: Meeting) -> JoinRoute? {
        guard let link = meeting.joinLink else { return nil }
        return ProfileResolver.route(for: link, choice: profileChoice(for: meeting), rules: prefs.profileRules,
                                     preferNative: prefs.preferNativeApps,
                                     nativeAvailable: { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil })
    }

    /// Meetings joined since launch, for the phone's Live Activity (it drops a joined meeting).
    @ObservationIgnored private var joinedIDs: Set<String> = []

    private func markJoined(_ meeting: Meeting) {
        guard !joinedIDs.contains(meeting.id) else { return }
        let cutoff = Calendar.current.startOfDay(for: Date())
        joinedIDs = joinedIDs.filter { id in allMeetings.contains { $0.id == id && $0.end > cutoff } }
        joinedIDs.insert(meeting.id)
        companion.pushSnapshot()
    }

    func join(_ meeting: Meeting) {
        onHandled?(meeting.id)
        markJoined(meeting)
        browsers.refresh()
        guard let route = joinRoute(for: meeting) else { return }
        switch route {
        case .native(let url), .defaultBrowser(let url): BrowserLauncher.open(url)
        case .profile(let profile, let url): BrowserLauncher.open(url, in: profile)
        }
    }

    enum ProfileMemory { case once, series }

    /// "Join in ▸ <profile>": opens in that profile now, optionally remembering it for this meeting or series.
    /// A nil profile means the default browser without a profile.
    func join(_ meeting: Meeting, in profile: BrowserProfile?, remember: ProfileMemory?) {
        guard let link = meeting.joinLink else { return }
        onHandled?(meeting.id)
        markJoined(meeting)
        if let remember, let profile {
            switch remember {
            case .once: prefs.profileRules.meetings[meeting.id] = profile.id
            case .series: prefs.profileRules.series[meeting.seriesID] = profile.id
            }
        }
        if let profile { BrowserLauncher.open(link.url, in: profile) } else { BrowserLauncher.open(link.url) }
    }

    /// Drops any per-meeting or per-series choice for `meeting`.
    func forgetProfileChoice(_ meeting: Meeting) {
        prefs.profileRules.meetings[meeting.id] = nil
        prefs.profileRules.series[meeting.seriesID] = nil
    }

    /// "Opens in Client A (Chrome)" for tooltips, or nil when nothing special happens.
    func joinHint(for meeting: Meeting) -> String? {
        guard let route = joinRoute(for: meeting) else { return nil }
        switch route {
        case .profile(let p, _): return "Opens in \(p.title) (\(p.browser.displayName))"
        case .native: return profileChoice(for: meeting).map { "Opens in the app (\($0.profile.title) is set for the browser)" }
        case .defaultBrowser: return nil
        }
    }

    func openInCalendar(_ meeting: Meeting) {
        // Calendar.app's (undocumented) ical://ekevent/<id> scheme reveals a specific event.
        let base = meeting.id.split(separator: "@").first.map(String.init) ?? meeting.id
        if let encoded = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            BrowserLauncher.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    // MARK: - iPhone companion

    /// What a paired phone mirrors: the same filtered, merged meetings the Mac shows, for the whole of
    /// today and tomorrow, so the phone keeps a full agenda (and its alerts) after it disconnects.
    func companionSnapshot() -> CompanionSnapshot {
        let cutoff = Calendar.current.startOfDay(for: Date())
        let mirrored = meetings.filter { $0.end > cutoff }.map { m -> Meeting in
            var m = m
            m.notes = nil // join links are already extracted; invite bodies can be huge
            return m
        }
        return CompanionSnapshot(macName: companion.macName, generatedAt: Date(), meetings: mirrored,
                                 suppressedIDs: suppressedByClash.union(agendaOnlyIDs),
                                 agendaOnlyIDs: agendaOnlyIDs, takeoverEnabled: prefs.takeoverEnabled,
                                 takeoverLeadSeconds: prefs.takeoverLeadSeconds,
                                 takeoverAutoDismissMinutes: prefs.takeoverAutoDismissMinutes,
                                 enrichments: enrichments.book.slice(for: mirrored),
                                 workSchedule: prefs.workSchedule,
                                 joinedIDs: joinedIDs.isEmpty ? nil : joinedIDs.filter { id in mirrored.contains { $0.id == id } })
    }

    /// A meeting by id, for actions coming from the phone.
    func meeting(id: String) -> Meeting? { meetings.first { $0.id == id } ?? allMeetings.first { $0.id == id } }

    // MARK: - Countdown panel

    /// What the floating panel shows, after hidden events and the "only within" window.
    var panelFocus: PanelFocus? {
        PanelPlanner.focus(meetings: activeMeetings, now: now, isHidden: isHiddenFromPanel,
                           withinMinutes: prefs.panelWithinMinutes, showDuringMeetings: prefs.panelShowDuringMeetings)
    }

    /// The style to draw now (grows as the meeting approaches when enabled).
    var panelStyle: PanelStyle {
        PanelPlanner.style(base: prefs.panelStyle, grow: prefs.panelGrow, focus: panelFocus, now: now)
    }

    func isHiddenFromPanel(_ m: Meeting) -> Bool {
        prefs.panelHiddenMeetings.contains(m.id) || prefs.panelHiddenSeries.contains(m.seriesID)
    }

    /// Whether `m` repeats (so "all occurrences" makes sense).
    func isRecurring(_ m: Meeting) -> Bool { m.recurs }

    func hideFromPanel(_ m: Meeting, series: Bool) {
        if series { prefs.panelHiddenSeries.insert(m.seriesID) } else { prefs.panelHiddenMeetings.insert(m.id) }
    }

    func showInPanel(_ m: Meeting) {
        prefs.panelHiddenMeetings.remove(m.id)
        prefs.panelHiddenSeries.remove(m.seriesID)
    }

    func isCalendarEnabled(_ id: String) -> Bool { !prefs.filters.disabledCalendarIDs.contains(id) }

    func setCalendar(_ id: String, enabled: Bool) {
        if enabled { prefs.filters.disabledCalendarIDs.remove(id) } else { prefs.filters.disabledCalendarIDs.insert(id) }
    }
}

enum InvitePromptReason { case daily, new, manual }
