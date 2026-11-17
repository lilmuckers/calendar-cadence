import CadenceCore
import Foundation

/// A source of calendar events. EventKit is the first; direct Google / ICS providers can conform later.
@MainActor
protocol CalendarProvider: AnyObject {
    var name: String { get }
    var isAuthorized: Bool { get }
    func requestAccess() async -> Bool
    func calendars() -> [CalendarInfo]
    func meetings(from start: Date, to end: Date) -> [Meeting]
    /// Called whenever the underlying store changes.
    var onChange: (() -> Void)? { get set }
}
