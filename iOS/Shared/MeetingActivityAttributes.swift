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
        /// Colour of the calendar the icon is anxious about (the meeting driving the mood). Nil from
        /// older builds: falls back to this meeting's colour.
        var iconRed: Double?
        var iconGreen: Double?
        var iconBlue: Double?
        /// Set while the activity counts down a focus stretch or break instead of a meeting (`title`
        /// is the moment's, `end` when it's over). Nil for meetings and from older builds.
        var pose: MascotPose?
        var momentDetail: String?
        /// A meeting with a join link: once it starts without a join it's missed (red, counting up
        /// from the start) until this date, after which it's gone. Nil for meetings without a link
        /// (they count down to their end), focus time, and older builds.
        var missedUntil: Date?
        /// Once `missedUntil` passes, say "Missed" with a disappointed icon instead of going away.
        var showsMissed: Bool?

        var isMoment: Bool { pose != nil }

        var target: Date { live ? end : start }

        /// Started without a join: drawn red, counting up.
        func missed(now: Date = Date()) -> Bool { missedUntil != nil && now >= start && !gone(now: now) }

        /// Missed for longer than it should linger. The app ends the activity when it next runs; until
        /// then the view says "Missed" (`showsMissed`) or draws next to nothing.
        func gone(now: Date = Date()) -> Bool { missedUntil.map { now >= $0 } ?? false }

        func mood(now: Date = Date()) -> ActivityMood {
            if missedUntil != nil, now >= start {
                guard gone(now: now) else { return .panicking }
                return showsMissed == true ? .disappointed : .calm
            }
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
