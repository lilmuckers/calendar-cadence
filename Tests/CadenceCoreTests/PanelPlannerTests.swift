import Foundation
import Testing
@testable import CadenceCore

private let now = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!

private func m(_ id: String, at minutes: Double, for length: Double = 30) -> Meeting {
    Meeting(id: id, title: id, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
            calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray))
}

@Suite("Countdown panel")
struct PanelPlannerTests {
    private func focus(_ ms: [Meeting], hidden: Set<String> = [], within: Int = 0, during: Bool = true) -> PanelFocus? {
        PanelPlanner.focus(meetings: ms, now: now, isHidden: { hidden.contains($0.id) }, withinMinutes: within, showDuringMeetings: during)
    }

    @Test func nextMeeting() {
        #expect(focus([m("a", at: 30)])?.meeting.id == "a")
    }

    @Test func hiddenMeetingsAreSkipped() {
        #expect(focus([m("a", at: 30), m("b", at: 60)], hidden: ["a"])?.meeting.id == "b")
    }

    @Test func withinWindow() {
        #expect(focus([m("a", at: 30)], within: 15) == nil)
        #expect(focus([m("a", at: 10)], within: 15)?.meeting.id == "a")
    }

    @Test func liveMeetingUnlessNextIsClose() {
        let live = m("live", at: -10, for: 60)
        #expect(focus([live, m("next", at: 30)]) == PanelFocus(meeting: live, live: true))
        #expect(focus([live, m("next", at: 5)])?.meeting.id == "next")
        #expect(focus([live, m("next", at: 30)], during: false)?.meeting.id == "next")
        #expect(focus([live, m("next", at: 30)], within: 15, during: false) == nil)
    }

    @Test func growSteps() {
        let f = { (minutes: Double) in PanelFocus(meeting: m("a", at: minutes), live: false) }
        #expect(PanelPlanner.style(base: .mini, grow: true, focus: f(30), now: now) == .mini)
        #expect(PanelPlanner.style(base: .mini, grow: true, focus: f(12), now: now) == .compact)
        #expect(PanelPlanner.style(base: .mini, grow: true, focus: f(4), now: now) == .standard)
        #expect(PanelPlanner.style(base: .compact, grow: true, focus: f(12), now: now) == .standard)
        #expect(PanelPlanner.style(base: .mini, grow: false, focus: f(4), now: now) == .mini)
        #expect(PanelPlanner.style(base: .standard, grow: true, focus: f(30), now: now) == .standard)
    }

    @Test(arguments: [
        ("ABC123@1800000000", "ABC123"),
        ("ics:feed:uid-1@1800000000", "ics:feed:uid-1"),
        ("gcal:acct:cal@x.com:abc123_20261117T100000Z", "gcal:acct:cal@x.com:abc123"),
        ("gcal:acct:cal@x.com:single", "gcal:acct:cal@x.com:single"),
        ("demo-Standup", "demo-Standup"),
    ])
    func seriesID(id: String, expected: String) {
        var meeting = m("x", at: 0)
        meeting.id = id
        #expect(meeting.seriesID == expected)
    }
}
