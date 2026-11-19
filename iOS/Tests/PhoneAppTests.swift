import CadenceCore
import Foundation
import Testing
@testable import Cadence

// iPhone-only logic. The shared CadenceCore suite (Tests/CadenceCoreTests) also runs in this
// bundle, so the core is checked on iOS as well as on the Mac.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func meeting(link: Bool = false, location: String? = nil, attendees: Int = 0) -> Meeting {
    Meeting(id: "a", title: "Design Review", start: now, end: now.addingTimeInterval(1800),
            calendar: CalendarInfo(id: "c", title: "Work", sourceTitle: "Google", color: .gray, kind: .google),
            location: location, attendeeCount: attendees,
            joinLink: link ? MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!) : nil)
}

@Suite("Phone preferences")
struct PhonePrefsTests {
    @Test func roundTrips() throws {
        var prefs = PhonePrefs()
        prefs.wrapUpEnabled = true
        prefs.takeoverLeadSeconds = 90
        prefs.liveActivityLeadMinutes = 10
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(PhonePrefs.self, from: data) == prefs)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(PhonePrefs.self, from: Data(#"{"headsUpMinutes": 2}"#.utf8))
        var expected = PhonePrefs()
        expected.headsUpMinutes = 2
        #expect(decoded == expected)
    }

    @Test func wrongTypesFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(PhonePrefs.self, from: Data(#"{"alertSound": "loud", "wrapUpMinutes": 3}"#.utf8))
        #expect(decoded.alertSound == PhonePrefs().alertSound)
        #expect(decoded.wrapUpMinutes == 3)
    }

    @Test func wrapUpsAreOffByDefault() {
        // The phone can't tell whether you're still on a call, so it doesn't nag unless asked.
        #expect(PhonePrefs().wrapUpEnabled == false)
    }
}

@Suite("Phone theme")
struct ThemeTests {
    @Test func detailPrefersTheServiceAndCountsPeople() {
        #expect(Theme.detail(meeting(link: true, location: "Room 4", attendees: 6)) == "Zoom · 6 people")
    }

    @Test func detailFallsBackToPlaceThenCalendar() {
        #expect(Theme.detail(meeting(location: "Room 4")) == "Room 4")
        #expect(Theme.detail(meeting()) == "Work")
    }

    @Test func allDayRange() {
        var m = meeting()
        m.isAllDay = true
        #expect(Theme.range(m) == "All day")
    }
}

@Suite("Paired Mac nickname")
struct PairedMacTests {
    @Test func oldSavedMacStillDecodes() throws {
        let json = #"{"id":"m1","name":"C02XK1ABCDEF","hosts":["192.168.0.21"],"port":62166}"#
        let mac = try JSONDecoder().decode(PairedMac.self, from: Data(json.utf8))
        #expect(mac.nickname == nil)
        #expect(mac.displayName == "C02XK1ABCDEF")
    }

    @Test func nicknameWinsAndRoundTrips() throws {
        let mac = PairedMac(id: "m1", name: "C02XK1ABCDEF", nickname: "Work laptop")
        #expect(mac.displayName == "Work laptop")
        let back = try JSONDecoder().decode(PairedMac.self, from: JSONEncoder().encode(mac))
        #expect(back == mac)
    }
}

@Suite("Widget schedule")
struct WidgetScheduleTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 10:00 UTC on the test day.
    private var morning: Date { cal.date(bySettingHour: 10, minute: 0, second: 0, of: now)! }

    private func item(_ id: String, inMinutes: Double, length: Double = 30) -> WidgetMeeting {
        let start = morning.addingTimeInterval(inMinutes * 60)
        return WidgetMeeting(id: id, title: id, start: start, end: start.addingTimeInterval(length * 60),
                             red: 0.2, green: 0.4, blue: 0.8, hasLink: false)
    }

    @Test func nextIsTheNextToStartToday() {
        let schedule = WidgetSchedule(meetings: [item("started", inMinutes: -10), item("later", inMinutes: 90),
                                                 item("soon", inMinutes: 20), item("tomorrow", inMinutes: 18 * 60)],
                                      generatedAt: morning)
        #expect(schedule.next(after: morning, calendar: cal)?.id == "soon")
        #expect(schedule.following(schedule.next(after: morning, calendar: cal)!, calendar: cal)?.id == "later")
    }

    @Test func nothingLeftTodayMeansNoNext() {
        let schedule = WidgetSchedule(meetings: [item("started", inMinutes: -10), item("tomorrow", inMinutes: 18 * 60)],
                                      generatedAt: morning)
        #expect(schedule.next(after: morning, calendar: cal) == nil)
        #expect(schedule.mood(at: morning, calendar: cal) == .calm)
    }

    @Test func moodFollowsTheNextMeeting() {
        let schedule = WidgetSchedule(meetings: [item("soon", inMinutes: 20)], generatedAt: morning)
        #expect(schedule.mood(at: morning, calendar: cal) == .calm)
        #expect(schedule.mood(at: morning.addingTimeInterval(10 * 60), calendar: cal) == .nervous)
        #expect(schedule.mood(at: morning.addingTimeInterval(17 * 60), calendar: cal) == .panicking)
    }

    @Test func entryDatesCoverStartsMoodsAndMidnight() {
        let schedule = WidgetSchedule(meetings: [item("soon", inMinutes: 10), item("later", inMinutes: 60),
                                                 item("tomorrow", inMinutes: 18 * 60)],
                                      generatedAt: morning)
        let dates = schedule.entryDates(from: morning, calendar: cal)
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: morning))!
        let m = { (minutes: Double) in morning.addingTimeInterval(minutes * 60) }
        // "soon" is already inside its nervous lead, so only its panic point and start count.
        #expect(dates == [morning, m(5), m(10), m(45), m(55), m(60), midnight])
    }

    @Test func roundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "WidgetScheduleTests"))
        defer { defaults.removePersistentDomain(forName: "WidgetScheduleTests") }
        let schedule = WidgetSchedule(meetings: [item("soon", inMinutes: 10)], generatedAt: morning)
        schedule.save(to: defaults)
        #expect(WidgetSchedule.load(from: defaults) == schedule)
    }
}
