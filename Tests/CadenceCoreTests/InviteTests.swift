import Foundation
import Testing
@testable import CadenceCore

@Suite("Invites")
struct InviteTests {
    private let now = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!

    private func invite(_ id: String, inDays days: Double, recurs: Bool = false, status: Participation = .pending, title: String? = nil) -> Meeting {
        var m = Meeting(id: id, title: title ?? id, start: now.addingTimeInterval(days * 86_400 + 3600),
                        end: now.addingTimeInterval(days * 86_400 + 5400),
                        calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray),
                        organizer: "Boss", participation: status)
        m.recurs = recurs
        return m
    }

    @Test func horizons() {
        let all = [invite("today", inDays: 0), invite("tomorrow", inDays: 1), invite("five", inDays: 5),
                   invite("month", inDays: 30), invite("answered", inDays: 0, status: .accepted)]
        #expect(InvitePlanner.pending(all, now: now, horizon: .today).map(\.id) == ["today"])
        #expect(InvitePlanner.pending(all, now: now, horizon: .twoDays).map(\.id) == ["today", "tomorrow"])
        #expect(InvitePlanner.pending(all, now: now, horizon: .week).count == 3)
        #expect(InvitePlanner.pending(all, now: now, horizon: .all).count == 4)
    }

    @Test func recurringSeriesThatStartedEarlierStillCounts() {
        let series = invite("weekly", inDays: -14, recurs: true)
        #expect(InvitePlanner.pending([series], now: now, horizon: .today).map(\.id) == ["weekly"])
    }

    @Test func mergePrefersRespondableCopy() {
        let local = invite("ek@1", inDays: 1, title: "Planning")
        let google = invite("gcal:x", inDays: 1, title: "Planning")
        let out = InvitePlanner.merge([local, google]) { $0.id.hasPrefix("gcal") }
        #expect(out.map(\.id) == ["gcal:x"])
    }

    @Test func newInvitesNeedHistory() {
        let a = invite("a", inDays: 0), b = invite("b", inDays: 1)
        #expect(InvitePlanner.newInvites([a, b], known: nil).isEmpty)
        #expect(InvitePlanner.newInvites([a, b], known: ["a"]).map(\.id) == ["b"])
    }

    @Test func paletteMatchesGoogle() {
        #expect(EventColorChoice.palette.count == 11)
        #expect(EventColorChoice.choice(id: "5")?.name == "Banana")
    }
}
