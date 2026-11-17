import AppKit
import CadenceCore
import Observation

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
                || prefs.localEventColors != oldValue.localEventColors { recompute() }
            if prefs.inviteHorizon != oldValue.inviteHorizon || prefs.filters.disabledCalendarIDs != oldValue.filters.disabledCalendarIDs {
                Task { await refreshInvites() }
            }
            onPrefsChanged?()
        }
    }

    private(set) var calendars: [CalendarInfo] = []
    private(set) var allMeetings: [Meeting] = []
    private(set) var now = Date()
    private(set) var access: AccessState = .unknown
    private(set) var lastRefresh: Date?
    private(set) var lastRemoteRefresh: Date?
    /// Filtered and de-duplicated events across every source.
    private(set) var meetings: [Meeting] = []

    /// Set by the AppDelegate to show/hide windows when state changes.
    /// Fired when a meeting's alert is due. The optional style forces a presentation (used by Preview).
    @ObservationIgnored var onAlert: ((Meeting, BusyAlertStyle?) -> Void)?
    @ObservationIgnored var onPrefsChanged: (() -> Void)?
    /// Off while rendering screenshots so demo tweaks never touch the user's saved settings.
    @ObservationIgnored var persistPrefs = true
    @ObservationIgnored var onReminder: ((Reminder) -> Void)?
    /// Invites to show: `.daily` review, `.new` arrivals, or `.manual` from the menu or Settings.
    @ObservationIgnored var onInvites: (([Meeting], InvitePromptReason) -> Void)?
    /// A newly found clash the user hasn't decided on yet.
    @ObservationIgnored var onClash: ((Clash) -> Void)?

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
    @ObservationIgnored private var promptedClashes: Set<String> = []
    @ObservationIgnored private var sentReminders: Set<String> = []
    @ObservationIgnored private var travelTimes: [String: (eta: TimeInterval, at: Date)] = [:]
    @ObservationIgnored private var travelInFlight: Set<String> = []
    @ObservationIgnored private var travelFailures: [String: Date] = [:]

    @ObservationIgnored private let eventKit = EventKitProvider()
    @ObservationIgnored let googleAuth = GoogleAuth()
    @ObservationIgnored let microsoftAuth = MicrosoftAuth()
    /// One provider per signed-in Microsoft account.
    private(set) var microsoftProviders: [MicrosoftCalendarProvider] = []
    /// One provider per signed-in Google account.
    private(set) var googleProviders: [GoogleCalendarProvider] = []
    private(set) var icsProviders: [ICSProvider] = []
    @ObservationIgnored private var providers: [CalendarProvider] { [eventKit] + googleProviders + microsoftProviders + icsProviders }
    @ObservationIgnored private var planner = AlertPlanner()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        prefs = Preferences.load()
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
            await requestAccess()
            await refreshRemote()
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
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    func requestAccess() async {
        let granted = await eventKit.requestAccess()
        access = granted ? .granted : .denied
        refresh()
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
        lastRefresh = Date()
        recompute()
    }

    private func recompute() {
        meetings = visibleMeetings()
        clashes = ClashDetector.clashes(in: meetings, after: Date())
        let live = Set(clashes.map(\.key))
        clashChoices = clashChoices.filter { live.contains($0.key) }
        UserDefaults.standard.set(clashChoices, forKey: "Cadence.clashChoices")
        if prefs.clashPromptEnabled,
           let fresh = clashes.first(where: { clashChoices[$0.key] == nil && !promptedClashes.contains($0.key) }) {
            promptedClashes.insert(fresh.key)
            onClash?(fresh)
        }
    }

    private func visibleMeetings() -> [Meeting] {
        var shown = allMeetings.filter { prefs.filters.allows($0) }
        if !prefs.useEventColors { shown = shown.map { var m = $0; m.eventColor = nil; return m } }
        shown = shown.map(applyLocalColor)
        return MeetingDeduplicator.dedupe(shown)
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
        try await provider.respond(target, reply)
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
    func setColor(_ meeting: Meeting, _ choice: EventColorChoice?) async throws {
        if let (provider, target) = actionable(meeting, { $0.canSetColor($1) }) {
            try await provider.setColor(target, choice)
            prefs.localEventColors[colorKey(meeting)] = nil
        } else {
            prefs.localEventColors[colorKey(meeting)] = choice?.id
        }
        rebuildInvites(announce: false)
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

    func resolveClash(_ clash: Clash, choice: String?) {
        // nil = "decide later": alerts fire for everything, and we won't ask again this session.
        guard let choice else { return }
        clashChoices[clash.key] = choice
        UserDefaults.standard.set(clashChoices, forKey: "Cadence.clashChoices")
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
        meetings = visibleMeetings()
        clashes = ClashDetector.clashes(in: meetings, after: now)
    }

    // MARK: - Hotkey

    /// What the global "join" shortcut opens: a meeting starting within 10 minutes beats one that's
    /// already running; otherwise the live meeting; otherwise the next one today with a link.
    var joinTarget: Meeting? {
        let linked = meetings.filter { !$0.isAllDay && $0.joinLink != nil && $0.end > now && !suppressedByClash.contains($0.id) }
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
        let upcoming = meetings.filter { !$0.isAllDay && $0.start > now && !suppressedByClash.contains($0.id) }
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
            reminders += ReminderPlanner.wrapUps(live: live, all: meetings, minutes: prefs.wrapUpMinutes,
                                                 onlyBackToBack: prefs.wrapUpOnlyBackToBack)
        }
        if prefs.summaryEnabled, canShowAgenda, lastRefresh != nil,
           let summary = ReminderPlanner.morningSummary(meetings: meetings, now: now,
                                                        hour: prefs.summaryTime / 60, minute: prefs.summaryTime % 60),
           UserDefaults.standard.string(forKey: "Cadence.lastSummary") != summary.key {
            reminders.append(summary)
        }
        for r in ReminderPlanner.due(reminders, now: now, sent: sentReminders) {
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
        now = Date()
        // Belt and braces: EventKit notifies on change, but refetch every 5 minutes anyway.
        if let last = lastRefresh, now.timeIntervalSince(last) > 300 { refresh() }
        if let last = lastRemoteRefresh, now.timeIntervalSince(last) > 600 { Task { await refreshRemote() } }
        checkAlert()
        if Int(now.timeIntervalSince1970) % 5 == 0 {
            checkReminders()
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
        let doneToday = !todayMeetings.contains { !$0.isAllDay && $0.end > now }
        return doneToday || Calendar.current.component(.hour, from: now) >= prefs.tomorrowFromHour
    }

    /// Timed meetings happening right now.
    var current: [Meeting] { meetings.filter { !$0.isAllDay && $0.isInProgress(at: now) } }

    /// The next timed meeting that has not started yet.
    var next: Meeting? { meetings.first { !$0.isAllDay && $0.start > now } }

    var isNextToday: Bool {
        guard let next else { return false }
        return Calendar.current.isDate(next.start, inSameDayAs: now)
    }

    // MARK: - Alerts

    private func checkAlert() {
        guard prefs.takeoverEnabled else { return }
        let suppressed = suppressedByClash
        let candidates = meetings.filter {
            (!prefs.takeoverOnlyWithLink || $0.joinLink != nil) && !suppressed.contains($0.id)
        }
        guard let due = planner.due(in: candidates, now: now, leadTime: prefs.takeoverLeadSeconds) else { return }
        planner.markFired(due)
        onAlert?(due, nil)
    }

    func snooze(_ meeting: Meeting, seconds: TimeInterval = 60) {
        planner.snooze(meeting, until: Date().addingTimeInterval(seconds))
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

    // MARK: - Actions

    func join(_ meeting: Meeting) {
        guard let link = meeting.joinLink else { return }
        let ws = NSWorkspace.shared
        if prefs.preferNativeApps, let native = link.nativeURL, ws.urlForApplication(toOpen: native) != nil {
            ws.open(native)
        } else {
            ws.open(link.url)
        }
    }

    func openInCalendar(_ meeting: Meeting) {
        // Calendar.app's (undocumented) ical://ekevent/<id> scheme reveals a specific event.
        let base = meeting.id.split(separator: "@").first.map(String.init) ?? meeting.id
        if let encoded = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    // MARK: - Countdown panel

    /// What the floating panel shows, after hidden events and the "only within" window.
    var panelFocus: PanelFocus? {
        PanelPlanner.focus(meetings: meetings, now: now, isHidden: isHiddenFromPanel,
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
