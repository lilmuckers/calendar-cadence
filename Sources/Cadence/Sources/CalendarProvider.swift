import CadenceCore
import Foundation

/// A source of calendar events. Local providers (EventKit) answer synchronously; remote ones
/// (ICS feeds, Google) fetch in `refreshRemote()` and serve from their cache.
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
}

extension CalendarProvider {
    func refreshRemote() async {}
}
