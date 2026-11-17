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
