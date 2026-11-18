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
