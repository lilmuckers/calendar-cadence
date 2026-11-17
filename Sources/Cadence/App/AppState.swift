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
            if prefs.filters != oldValue.filters { recompute() }
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
    /// A newly found clash the user hasn't decided on yet.
    @ObservationIgnored var onClash: ((Clash) -> Void)?

    /// Clash key → chosen meeting id (or "all"). Persisted so a decision sticks across refreshes.
    private(set) var clashChoices: [String: String] = UserDefaults.standard.dictionary(forKey: "Cadence.clashChoices") as? [String: String] ?? [:]
    private(set) var clashes: [Clash] = []
    @ObservationIgnored private var promptedClashes: Set<String> = []
    @ObservationIgnored private var sentReminders: Set<String> = []
    @ObservationIgnored private var travelTimes: [String: (eta: TimeInterval, at: Date)] = [:]
    @ObservationIgnored private var travelInFlight: Set<String> = []
    @ObservationIgnored private var travelFailures: [String: Date] = [:]

    @ObservationIgnored private let eventKit = EventKitProvider()
    @ObservationIgnored let googleAuth = GoogleAuth()
    @ObservationIgnored private(set) lazy var google = GoogleCalendarProvider(auth: googleAuth)
    private(set) var icsProviders: [ICSProvider] = []
    @ObservationIgnored private var providers: [CalendarProvider] { [eventKit, google] + icsProviders }
    @ObservationIgnored private var planner = AlertPlanner()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        prefs = Preferences.load()
    }

    // MARK: - Lifecycle

    func start() {
        eventKit.onChange = { [weak self] in self?.refresh() }
        google.onChange = { [weak self] in self?.refresh() }
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
        meetings = MeetingDeduplicator.dedupe(allMeetings.filter { prefs.filters.allows($0) })
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
        meetings = MeetingDeduplicator.dedupe(allMeetings.filter { prefs.filters.allows($0) })
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
        for r in ReminderPlanner.due(reminders, now: now, sent: sentReminders) {
            sentReminders.insert(r.key)
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

    var hasRemoteSources: Bool { googleAuth.isSignedIn || !icsProviders.isEmpty }
    var canShowAgenda: Bool { access == .granted || hasRemoteSources }

    func googleSignIn() async throws {
        try await googleAuth.signIn()
        await google.refreshRemote()
    }

    func googleSignOut() {
        googleAuth.signOut()
        Task { await google.refreshRemote() }
    }

    private func tick() {
        now = Date()
        // Belt and braces: EventKit notifies on change, but refetch every 5 minutes anyway.
        if let last = lastRefresh, now.timeIntervalSince(last) > 300 { refresh() }
        if let last = lastRemoteRefresh, now.timeIntervalSince(last) > 600 { Task { await refreshRemote() } }
        checkAlert()
        if Int(now.timeIntervalSince1970) % 5 == 0 { checkReminders() }
    }

    // MARK: - Derived

    var todayMeetings: [Meeting] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return meetings.filter { $0.end > start && $0.start < end }
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

    func isCalendarEnabled(_ id: String) -> Bool { !prefs.filters.disabledCalendarIDs.contains(id) }

    func setCalendar(_ id: String, enabled: Bool) {
        if enabled { prefs.filters.disabledCalendarIDs.remove(id) } else { prefs.filters.disabledCalendarIDs.insert(id) }
    }
}
