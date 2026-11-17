import AppKit
import CadenceCore
import EventKit

/// Reads every account configured in macOS Calendar: iCloud, Google, Exchange/Outlook, CalDAV, subscriptions.
@MainActor
final class EventKitProvider: CalendarProvider {
    let name = "macOS Calendar"
    var onChange: (() -> Void)?

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var isDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        do {
            let granted = try await store.requestFullAccessToEvents()
            if granted { store.reset() }
            return granted
        } catch {
            NSLog("Cadence: calendar access failed: \(error)")
            return false
        }
    }

    func calendars() -> [CalendarInfo] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
            .map(Self.info)
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    func meetings(from start: Date, to end: Date) -> [Meeting] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.meeting)
    }

    /// Pending invitations, one per series (EventKit expands recurrences, and can't search past 4 years).
    func fetchInvites(until: Date?) async -> [Meeting] {
        guard isAuthorized else { return [] }
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = until ?? cal.date(byAdding: .year, value: 1, to: from)!
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        var seen: Set<String> = []
        return store.events(matching: predicate)
            .filter { $0.attendees?.first(where: \.isCurrentUser)?.participantStatus == .pending }
            .sorted { $0.startDate < $1.startDate }
            .filter { seen.insert($0.calendarItemIdentifier).inserted }
            .map(Self.meeting)
    }

    // MARK: - Mapping

    private static func info(_ cal: EKCalendar) -> CalendarInfo {
        CalendarInfo(
            id: cal.calendarIdentifier,
            title: cal.title,
            sourceTitle: cal.source?.title ?? "Other",
            color: rgba(cal.color)
        )
    }

    private static func rgba(_ color: NSColor?) -> RGBAColor {
        guard let c = color?.usingColorSpace(.sRGB) else { return .gray }
        return RGBAColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }

    private static func meeting(_ event: EKEvent) -> Meeting {
        let me = event.attendees?.first(where: \.isCurrentUser)
        let participation: Participation
        switch me?.participantStatus {
        case .accepted?: participation = .accepted
        case .declined?: participation = .declined
        case .tentative?: participation = .tentative
        case .pending?: participation = .pending
        default: participation = (event.organizer?.isCurrentUser ?? true) ? .accepted : .unknown
        }
        let availability: Availability
        switch event.availability {
        case .busy: availability = .busy
        case .free: availability = .free
        case .tentative: availability = .tentative
        case .unavailable: availability = .unavailable
        default: availability = .unknown
        }
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        return Meeting(
            id: "\(base)@\(Int(event.startDate.timeIntervalSince1970))",
            title: event.title?.isEmpty == false ? event.title : "Untitled",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            isCanceled: event.status == .canceled,
            calendar: info(event.calendar),
            location: event.location?.isEmpty == false ? event.location : nil,
            notes: event.notes,
            url: event.url,
            organizer: event.organizer?.name,
            attendeeCount: event.attendees?.count ?? 0,
            participation: participation,
            availability: availability,
            joinLink: MeetingLinkDetector.detect(url: event.url, location: event.location, notes: event.notes),
            recurs: event.hasRecurrenceRules || event.isDetached
        )
    }
}
