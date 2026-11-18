import CoreGraphics
import CadenceCore
import EventKit

/// Reads every account configured in the system Calendar: iCloud, Google, Exchange/Outlook, CalDAV, subscriptions.
@MainActor
final class EventKitProvider: CalendarProvider {
    #if os(macOS)
    let name = "macOS Calendar"
    #else
    let name = "iPhone Calendar"
    #endif
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
            color: rgba(cal.cgColor),
            kind: kind(cal)
        )
    }

    private static func kind(_ cal: EKCalendar) -> CalendarKind {
        if cal.type == .birthday { return .birthdays }
        if cal.type == .subscription { return .subscribed }
        let title = (cal.source?.title ?? "").lowercased()
        switch cal.source?.sourceType {
        case .local?: return .local
        case .exchange?: return .exchange
        case .birthdays?: return .birthdays
        case .subscribed?: return .subscribed
        case .calDAV?:
            if title.contains("icloud") { return .iCloud }
            if title.contains("google") || title.contains("gmail") { return .googleViaMac }
            return .calDAV
        default: return .other
        }
    }

    private static func rgba(_ color: CGColor?) -> RGBAColor {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color?.converted(to: srgb, intent: .defaultIntent, options: nil),
              let parts = c.components, parts.count >= 3 else { return .gray }
        return RGBAColor(red: parts[0], green: parts[1], blue: parts[2], alpha: c.alpha)
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
            organizerEmail: Self.email(event.organizer?.url),
            attendeeCount: event.attendees?.count ?? 0,
            attendees: (event.attendees ?? []).map { Attendee(name: $0.name, email: Self.email($0.url), isSelf: $0.isCurrentUser,
                                                         isResource: $0.participantType == .room || $0.participantType == .resource) },
            participation: participation,
            availability: availability,
            joinLink: MeetingLinkDetector.detect(url: event.url, location: event.location, notes: event.notes),
            recurs: event.hasRecurrenceRules || event.isDetached
        )
    }

    /// EventKit gives participants as `mailto:` URLs.
    private static func email(_ url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        let raw = url.absoluteString.dropFirst("mailto:".count)
        let v = (raw.removingPercentEncoding ?? String(raw)).split(separator: "?").first.map(String.init) ?? ""
        return v.contains("@") ? v : nil
    }
}
