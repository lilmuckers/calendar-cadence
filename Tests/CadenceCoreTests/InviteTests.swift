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

    @Test func calendarLabelsRenameSwatchesAndAddCustomColours() throws {
        let json = """
        {"labelProperties": {"eventLabels": [
            {"id": "a", "backgroundColor": "#33B679", "name": "Focus time"},
            {"id": "b", "backgroundColor": "#d50000", "name": ""},
            {"id": "c", "backgroundColor": "#123456", "name": "Side project"},
            {"id": "d", "backgroundColor": "nope", "name": "Broken"}
        ]}}
        """
        let labels = try JSONDecoder().decode(GoogleCalendarResource.self, from: Data(json.utf8)).labels
        let choices = EventColorChoice.palette(labels: labels)
        #expect(choices.count == 12)
        let sage = try #require(choices.first { $0.id == "2" })
        #expect(sage.name == "Focus time")
        #expect(sage.labelID == "a")
        #expect(sage.detail == "Focus time (Sage)")
        // An unnamed label keeps Google's name but still sets the label.
        let tomato = try #require(choices.first { $0.id == "11" })
        #expect(tomato.name == "Tomato" && tomato.labelID == "b" && tomato.detail == "Tomato")
        let custom = try #require(choices.last)
        #expect(custom.id == "label:c" && custom.name == "Side project" && custom.labelID == "c")
        #expect(EventColorChoice.palette(labels: []) == EventColorChoice.palette)
    }

    @Test func namedOnlyKeepsNamedLabelsAndCurrentColour() throws {
        let labels = [
            GoogleEventLabel(id: "a", backgroundColor: "#33B679", name: "Focus time"),
            GoogleEventLabel(id: "b", backgroundColor: "#d50000", name: ""),
            GoogleEventLabel(id: "c", backgroundColor: "#123456", name: "Side project"),
            GoogleEventLabel(id: "e", backgroundColor: "#654321", name: nil),
        ]
        let choices = EventColorChoice.palette(labels: labels)
        #expect(choices.count == 13)
        #expect(EventColorChoice.namedOnly(choices).map(\.id) == ["2", "label:c"])
        // The event's current colour stays even when unnamed.
        #expect(EventColorChoice.namedOnly(choices, keeping: "label:e").map(\.id) == ["2", "label:c", "label:e"])
        // Nothing named: show everything.
        let plain = EventColorChoice.palette(labels: [GoogleEventLabel(id: "x", backgroundColor: "#654321", name: nil)])
        #expect(EventColorChoice.namedOnly(plain, keeping: "11") == plain)
    }

    @Test func eventLabelColourWinsOverLegacyColorId() throws {
        let json = """
        {"id": "e1", "summary": "Deep work", "colorId": "5", "eventLabelId": "c",
         "start": {"dateTime": "2026-11-18T10:00:00Z"}, "end": {"dateTime": "2026-11-18T11:00:00Z"}}
        """
        let event = try JSONDecoder().decode(GoogleEvent.self, from: Data(json.utf8))
        let cal = CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray)
        let custom = GoogleMapper.color(hex: "#123456")
        #expect(GoogleMapper.meeting(event, calendar: cal, labels: ["c": custom])?.eventColor == custom)
        #expect(GoogleMapper.meeting(event, calendar: cal)?.eventColor == GoogleMapper.eventColor(id: "5"))
    }
}
