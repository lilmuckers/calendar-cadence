import CadenceCore
import Foundation

/// A source of calendar events. Local providers (EventKit) answer synchronously; remote ones
/// (ICS feeds, Google, Microsoft) fetch in `refreshRemote()` and serve from their cache.
@MainActor
protocol CalendarProvider: AnyObject {
    var name: String { get }
    var isAuthorized: Bool { get }
    func requestAccess() async -> Bool
    func calendars() -> [CalendarInfo]
    func meetings(from start: Date, to end: Date) -> [Meeting]
    /// Fetch fresh data from the network. No-op for local providers.
    func refreshRemote() async
    /// Called whenever the underlying data changes.
    var onChange: (() -> Void)? { get set }

    /// Invitations still awaiting a reply from now until `until` (nil = no limit).
    func fetchInvites(until: Date?) async -> [Meeting]
    /// Whether this source can send an RSVP for `meeting` itself.
    func canRespond(_ meeting: Meeting) -> Bool
    func respond(_ meeting: Meeting, _ reply: RSVP) async throws
    /// Whether this source can store an event colour (otherwise Cadence keeps it locally).
    func canSetColor(_ meeting: Meeting) -> Bool
    func setColor(_ meeting: Meeting, _ choice: EventColorChoice?) async throws
    /// The colours this source offers for `meeting` with its own names (Google colour labels), or nil for the standard palette.
    func colorChoices(for meeting: Meeting) -> [EventColorChoice]?
}

/// The one URLSession for every network call (calendar APIs, feeds, sign-in, messages, avatars).
/// Ephemeral with no URL cache: `URLSession.shared` keeps every response in memory and in
/// ~/Library/Caches (calendar data on disk, megabytes of it), and none of it is ever reused because
/// every fetch wants fresh data. Bounded timeouts so a dead socket after sleep can't hang a refresh.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// Deletes the response cache older builds left behind via `URLSession.shared`.
    static func removeLegacyCache() {
        // Files only: touching URLCache.shared would create a fresh (empty) Cache.db.
        guard let id = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent(id, isDirectory: true)
        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

enum ProviderError: LocalizedError {
    case unsupported
    case needsReconnect(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "This calendar can't do that from Cadence."
        case .needsReconnect(let account): "Reconnect \(account) in Settings → Accounts to let Cadence reply to invites and set colours."
        case .http(let code, let body): "Server error \(code): \(body.prefix(200))"
        }
    }
}

extension CalendarProvider {
    func refreshRemote() async {}
    func fetchInvites(until: Date?) async -> [Meeting] { [] }
    func canRespond(_ meeting: Meeting) -> Bool { false }
    func respond(_ meeting: Meeting, _ reply: RSVP) async throws { throw ProviderError.unsupported }
    func canSetColor(_ meeting: Meeting) -> Bool { false }
    func setColor(_ meeting: Meeting, _ choice: EventColorChoice?) async throws { throw ProviderError.unsupported }
    func colorChoices(for meeting: Meeting) -> [EventColorChoice]? { nil }

    func owns(_ meeting: Meeting) -> Bool { calendars().contains { $0.id == meeting.calendar.id } }
}
