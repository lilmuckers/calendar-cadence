import Foundation
import Testing
@testable import CadenceCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func m(_ id: String, _ title: String? = nil, at minutes: Double, for length: Double = 30, location: String? = nil) -> Meeting {
    Meeting(id: id, title: title ?? id, start: t0.addingTimeInterval(minutes * 60), end: t0.addingTimeInterval((minutes + length) * 60),
            calendar: CalendarInfo(id: "c", title: "Work", sourceTitle: "s", color: .gray), location: location)
}

@Suite("Reminders")
struct ReminderTests {
    @Test func headsUpFiresOnceInWindow() {
        let r = ReminderPlanner.headsUps(for: [m("a", at: 10)], minutes: 5)
        #expect(ReminderPlanner.due(r, now: t0.addingTimeInterval(4 * 60), sent: []).isEmpty)
        #expect(ReminderPlanner.due(r, now: t0.addingTimeInterval(5 * 60), sent: []).count == 1)
        #expect(ReminderPlanner.due(r, now: t0.addingTimeInterval(5 * 60), sent: [r[0].key]).isEmpty)
    }

    @Test func staleRemindersAreDropped() {
        let r = ReminderPlanner.headsUps(for: [m("a", at: 10)], minutes: 5)
        #expect(ReminderPlanner.due(r, now: t0.addingTimeInterval(9 * 60), sent: []).isEmpty)
    }

    @Test func leaveOffsets() {
        let meeting = m("a", at: 60, location: "1 Main St")
        let r = ReminderPlanner.leaves(for: meeting, travel: 25 * 60, offsets: [0, 10, 10])
        #expect(r.count == 2)
        #expect(r.map(\.fireAt) == [t0.addingTimeInterval(25 * 60), t0.addingTimeInterval(35 * 60)])
        let msg = ReminderPlanner.message(for: r[1])
        #expect(msg.title == "Time to leave for a")
        #expect(msg.body.contains("25m"))
        #expect(ReminderPlanner.message(for: r[0]).title == "Leave in 10 min for a")
    }
}

@Suite("Clashes")
struct ClashTests {
    @Test func overlapsCluster() {
        let c = ClashDetector.clashes(in: [m("a", at: 0), m("b", at: 15), m("c", at: 45), m("d", at: 120)], after: t0)
        #expect(c.count == 1)
        #expect(c[0].meetings.map(\.id) == ["a", "b"])
    }

    @Test func backToBackAndCopiesAreFine() {
        #expect(ClashDetector.clashes(in: [m("a", at: 0), m("b", at: 30)], after: t0).isEmpty)
        #expect(ClashDetector.clashes(in: [m("a", "Sync", at: 0), m("b", "Sync", at: 0)], after: t0).isEmpty)
    }

    @Test func chainedOverlapsFormOneCluster() {
        let c = ClashDetector.clashes(in: [m("a", at: 0, for: 60), m("b", at: 30), m("c", at: 50)], after: t0)
        #expect(c.first?.meetings.count == 3)
    }

    @Test func pastClashesIgnored() {
        #expect(ClashDetector.clashes(in: [m("a", at: -60), m("b", at: -50)], after: t0).isEmpty)
    }

    @Test func suppression() {
        let clash = ClashDetector.clashes(in: [m("a", at: 0), m("b", at: 10)], after: t0)
        #expect(ClashDetector.suppressed(clashes: clash, choices: [clash[0].key: "b"]) == ["a"])
        #expect(ClashDetector.suppressed(clashes: clash, choices: [clash[0].key: "all"]).isEmpty)
        #expect(ClashDetector.suppressed(clashes: clash, choices: [:]).isEmpty)
    }
}

@Suite("Wrap-up and summary")
struct WrapUpTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func mt(_ id: String, _ from: Double, _ to: Double) -> Meeting {
        Meeting(id: id, title: id, start: base.addingTimeInterval(from * 60), end: base.addingTimeInterval(to * 60),
                calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray))
    }

    @Test func namesBackToBackMeeting() {
        let live = mt("live", 0, 30), next = mt("next", 30, 60), later = mt("later", 45, 90)
        let r = ReminderPlanner.wrapUps(live: [live], all: [live, next, later], minutes: 5, onlyBackToBack: false)
        #expect(r.count == 1)
        #expect(r[0].fireAt == live.end.addingTimeInterval(-300))
        #expect(r[0].joinTarget.id == "next")
        #expect(ReminderPlanner.message(for: r[0]).title == "Dude, you have 5 minutes to the next meeting and you're still talking")
        // Due during the meeting, not after it ends.
        #expect(ReminderPlanner.due(r, now: base.addingTimeInterval(25 * 60 + 10), sent: []).count == 1)
        #expect(ReminderPlanner.due(r, now: base.addingTimeInterval(31 * 60), sent: []).isEmpty)
    }

    @Test func plainWrapUpAndBackToBackOnly() {
        let live = mt("live", 0, 30), gap = mt("gap", 45, 60)
        let r = ReminderPlanner.wrapUps(live: [live], all: [live, gap], minutes: 5, onlyBackToBack: false)
        #expect(r.first?.joinTarget.id == "live")
        #expect(ReminderPlanner.message(for: r[0]).title == "live ends in 5 min")
        #expect(ReminderPlanner.wrapUps(live: [live], all: [live, gap], minutes: 5, onlyBackToBack: true).isEmpty)
    }

    @Test func summaryFiresLateButOnce() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: base)
        let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let m = Meeting(id: "a", title: "Standup", start: nine.addingTimeInterval(1800), end: nine.addingTimeInterval(2700),
                        calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray))
        let s = ReminderPlanner.morningSummary(meetings: [m], now: nine.addingTimeInterval(3600), hour: 8, minute: 30)!
        #expect(ReminderPlanner.due([s], now: nine.addingTimeInterval(3600), sent: []).count == 1)
        #expect(ReminderPlanner.due([s], now: nine.addingTimeInterval(3600), sent: [s.key]).isEmpty)
        #expect(ReminderPlanner.message(for: s).title == "Good morning — 1 meeting today")
    }
}
