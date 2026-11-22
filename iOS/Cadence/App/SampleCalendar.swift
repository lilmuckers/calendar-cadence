import CadenceCore
import Foundation

/// "Try with sample meetings": a made-up day, generated on the phone, so the countdown, desk mode
/// and the full-screen alert can be seen before connecting anything. A 30-minute meeting on every
/// hour (the same rota as the App Review feed in docs/demo), lunch at 12 with no link, and a short
/// "Welcome to Cadence" two minutes after it's turned on, so the alert shows up quickly.
/// Join opens a real, empty Jitsi room.
final class SampleCalendar: CalendarProvider {
    static let calendarID = "sample"

    /// When the sample was turned on: the welcome meeting is placed after it.
    let since: Date
    var onChange: (() -> Void)?

    init(since: Date) { self.since = since }

    var name: String { "Sample meetings" }
    var isAuthorized: Bool { true }
    func requestAccess() async -> Bool { true }

    static let info = CalendarInfo(id: calendarID, title: "Sample", sourceTitle: "Sample meetings",
                                   color: RGBAColor(red: 0.42, green: 0.48, blue: 1.0), kind: .other)

    func calendars() -> [CalendarInfo] { [Self.info] }

    private static let rota: [(title: String, room: String, people: Int)] = [
        ("Team stand-up", "Standup", 6),
        ("Design review", "Design", 4),
        ("1:1 with Alex", "OneOnOne", 2),
        ("Roadmap planning", "Roadmap", 8),
        ("Customer call: Northwind", "Northwind", 5),
        ("Sprint retro", "Retro", 7),
        ("Interview: iOS engineer", "Interview", 3),
        ("Weekly sync", "Sync", 9),
    ]

    func meetings(from start: Date, to end: Date) -> [Meeting] {
        let cal = Calendar.current
        let welcomeStart = since.addingTimeInterval(120)
        let welcome = Meeting(
            id: "sample-welcome-\(Int(since.timeIntervalSince1970))", title: "Welcome to Cadence",
            start: welcomeStart, end: welcomeStart.addingTimeInterval(15 * 60), calendar: Self.info,
            notes: "A sample meeting, two minutes after turning sample meetings on, to show the full-screen alert.",
            attendeeCount: 2, joinLink: Self.link("Welcome"))
        var out: [Meeting] = []
        if welcome.end > start && welcome.start < end { out.append(welcome) }
        var day = cal.startOfDay(for: start)
        while day < end {
            for hour in 0..<24 {
                guard let s = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { continue }
                let e = s.addingTimeInterval(30 * 60)
                guard e > start, s < end else { continue }
                // Leave room for the welcome meeting rather than double-booking it.
                if s < welcome.end && welcome.start < e { continue }
                out.append(Self.meeting(hour: hour, start: s, end: e))
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out.sorted { $0.start < $1.start }
    }

    private static func meeting(hour: Int, start: Date, end: Date) -> Meeting {
        let id = "sample-\(Int(start.timeIntervalSince1970))"
        if hour == 12 {
            return Meeting(id: id, title: "Lunch with Sam", start: start, end: end, calendar: info,
                           location: "Ferry Building, San Francisco", attendeeCount: 2, recurs: true)
        }
        let r = rota[hour % rota.count]
        return Meeting(id: id, title: r.title, start: start, end: end, calendar: info,
                       attendeeCount: r.people, joinLink: link("\(r.room)-\(String(format: "%02d", hour))"),
                       recurs: true)
    }

    private static func link(_ room: String) -> MeetingLink {
        MeetingLink(service: .jitsi, url: URL(string: "https://meet.jit.si/CadenceDemo-\(room)")!)
    }
}
