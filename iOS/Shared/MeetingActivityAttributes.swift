import ActivityKit
import Foundation

/// The Live Activity on the Lock Screen, in StandBy and in the Dynamic Island. One activity follows
/// whatever's next: its content changes as meetings come and go.
struct MeetingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var meetingID: String
        var title: String
        var start: Date
        var end: Date
        /// In progress (counting down to the end) rather than upcoming.
        var live: Bool
        var calendarTitle: String
        var serviceName: String?
        var serviceSymbol: String?
        var location: String?
        var hasLink: Bool
        var red: Double
        var green: Double
        var blue: Double
        var nextTitle: String?
        var nextStart: Date?
        /// Name of the Mac that Join will open on, if connected when this was last updated.
        var joinsOn: String?
        /// When the countdown takes over from the plain start time. The activity can be started early
        /// (iOS only lets the app start one while it's open), so until then it just says when.
        var countdownFrom: Date
        /// When the googly-eyed icon gets nervous, then panics (the Mac's menu bar stages), counted
        /// from the next meeting to start. Nil = nothing coming up, so it stays calm.
        var nervousFrom: Date?
        var panicFrom: Date?
        /// The stage when this was last updated. Changing it is what makes the app push an update at
        /// each switch; the view still works the stage out from the clock when it's drawn.
        var mood: ActivityMood = .calm

        var target: Date { live ? end : start }

        func mood(now: Date = Date()) -> ActivityMood {
            if let panicFrom, now >= panicFrom { return .panicking }
            if let nervousFrom, now >= nervousFrom { return .nervous }
            return .calm
        }

        /// The next stage switch after `now`, if any.
        func nextMoodChange(after now: Date = Date()) -> Date? {
            [nervousFrom, panicFrom].compactMap { $0 }.filter { $0 > now }.min()
        }

        /// Counting down yet? `stale` is true once the system passes the stale date, which is set to
        /// `countdownFrom` for an early activity, so the view flips to the countdown on its own.
        func counting(stale: Bool, now: Date = Date()) -> Bool { live || stale || now >= countdownFrom }

        /// Opens Cadence and joins (on the Mac when connected, else on the phone).
        var joinURL: URL { URL(string: "cadence-companion://join?id=\(meetingID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")! }
    }
}
