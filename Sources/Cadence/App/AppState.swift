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
            prefs.save()
            onPrefsChanged?()
        }
    }

    private(set) var calendars: [CalendarInfo] = []
    private(set) var allMeetings: [Meeting] = []
    private(set) var now = Date()
    private(set) var access: AccessState = .unknown
    private(set) var lastRefresh: Date?

    /// Set by the AppDelegate to show/hide windows when state changes.
    @ObservationIgnored var onAlert: ((Meeting) -> Void)?
    @ObservationIgnored var onPrefsChanged: (() -> Void)?

    @ObservationIgnored private let eventKit = EventKitProvider()
    @ObservationIgnored private var providers: [CalendarProvider] { [eventKit] }
    @ObservationIgnored private var planner = AlertPlanner()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        prefs = Preferences.load()
    }

    // MARK: - Lifecycle

    func start() {
        for provider in providers {
            provider.onChange = { [weak self] in self?.refresh() }
        }
        Task { await requestAccess() }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
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
    }

    private func tick() {
        now = Date()
        // Belt and braces: EventKit notifies on change, but refetch every 5 minutes anyway.
        if let last = lastRefresh, now.timeIntervalSince(last) > 300 { refresh() }
        checkAlert()
    }

    // MARK: - Derived

    /// Events passing the user's filters.
    var meetings: [Meeting] { allMeetings.filter { prefs.filters.allows($0) } }

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
        let candidates = meetings.filter { !prefs.takeoverOnlyWithLink || $0.joinLink != nil }
        guard let due = planner.due(in: candidates, now: now, leadTime: prefs.takeoverLeadSeconds) else { return }
        planner.markFired(due)
        onAlert?(due)
    }

    func snooze(_ meeting: Meeting, seconds: TimeInterval = 60) {
        planner.snooze(meeting, until: Date().addingTimeInterval(seconds))
    }

    /// Fire the takeover now for the next meeting (Settings → Alerts → Preview).
    func previewAlert() {
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
        onAlert?(sample)
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
