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

        var target: Date { live ? end : start }

        /// Opens Cadence and joins (on the Mac when connected, else on the phone).
        var joinURL: URL { URL(string: "cadence-companion://join?id=\(meetingID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")! }
    }
}
