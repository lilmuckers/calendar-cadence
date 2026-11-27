import Foundation
import Testing
@testable import CadenceCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func meeting(_ id: String, _ title: String = "Design Review", at minutes: Double = 10,
                     url: String? = "https://zoom.us/j/1") -> Meeting {
    Meeting(id: id, title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval(minutes * 60 + 1800),
            calendar: CalendarInfo(id: "c", title: "Work", sourceTitle: "Google", color: .gray, kind: .google),
            joinLink: url.map { MeetingLink(service: .zoom, url: URL(string: $0)!) })
}

private func snap(_ meetings: [Meeting], suppressed: Set<String> = []) -> CompanionSnapshot {
    CompanionSnapshot(macName: "Mac", generatedAt: now, meetings: meetings, suppressedIDs: suppressed)
}

@Suite("Several Macs")
struct MultiMacTests {
    @Test func sameMeetingFromTwoMacsShowsOnceAndKeepsEachCopy() {
        let agenda = MultiMacAgenda(agendas: [
            MacAgenda(macID: "work", snapshot: snap([meeting("w1"), meeting("w2", "Standup", at: 60)])),
            MacAgenda(macID: "home", snapshot: snap([meeting("h1"), meeting("h2", "Dentist", at: 120)])),
        ])
        #expect(agenda.meetings.map(\.title) == ["Design Review", "Standup", "Dentist"])
        let review = agenda.meetings[0]
        #expect(agenda.copies(of: review).map(\.macID) == ["work", "home"])
        #expect(Set(agenda.copies(of: review).map(\.meeting.id)) == ["w1", "h1"])
        #expect(agenda.copies(of: agenda.meetings[2]).map(\.macID) == ["home"])
    }

    @Test func aMuteOnOneMacCoversEveryCopy() {
        let agenda = MultiMacAgenda(agendas: [
            MacAgenda(macID: "work", snapshot: snap([meeting("w1")], suppressed: ["w1"])),
            MacAgenda(macID: "home", snapshot: snap([meeting("h1")])),
        ])
        #expect(agenda.suppressedIDs == ["w1", "h1"])
    }

    @Test func sharedMeetingOpensOnTheHighestPriorityMacThatHasIt() {
        let target = MacJoinRouting.target(sources: ["home", "work"], connected: ["work", "home"],
                                           canTakeLinks: [], link: nil, preferPriorityMac: false)
        #expect(target == "work")
    }

    @Test func singleSourceOpensWhereItCameFrom() {
        let link = MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!)
        #expect(MacJoinRouting.target(sources: ["home"], connected: ["work", "home"], canTakeLinks: ["work", "home"],
                                      link: link, preferPriorityMac: false) == "home")
    }

    @Test func singleSourceWebLinkCanGoToThePriorityMac() {
        let web = MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!)
        #expect(MacJoinRouting.target(sources: ["home"], connected: ["work", "home"], canTakeLinks: ["work", "home"],
                                      link: web, preferPriorityMac: true) == "work")
        // An app-only link stays where it came from.
        let app = MeetingLink(service: .zoom, url: URL(string: "zoommtg://zoom.us/join?confno=1")!)
        #expect(MacJoinRouting.target(sources: ["home"], connected: ["work", "home"], canTakeLinks: ["work", "home"],
                                      link: app, preferPriorityMac: true) == "home")
        // An older priority Mac that can't open other Macs' meetings: stays where it came from.
        #expect(MacJoinRouting.target(sources: ["home"], connected: ["work", "home"], canTakeLinks: ["home"],
                                      link: web, preferPriorityMac: true) == "home")
    }

    @Test func meetingNoConnectedMacHasOpensOnAMacOnlyForWebLinks() {
        let web = MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!)
        #expect(MacJoinRouting.target(sources: ["office"], connected: ["work"], canTakeLinks: ["work"],
                                      link: web, preferPriorityMac: false) == "work")
        #expect(MacJoinRouting.target(sources: [], connected: ["work"], canTakeLinks: ["work"],
                                      link: nil, preferPriorityMac: true) == nil)
    }
}

private func snap(_ meetings: [Meeting], at minutes: Double) -> CompanionSnapshot {
    CompanionSnapshot(macName: "Mac", generatedAt: now.addingTimeInterval(minutes * 60), meetings: meetings)
}

@Suite("Saved agendas while the Macs are out of reach")
struct DroppedMeetingTests {
    @Test func aMeetingCancelledOnOneMacStaysGoneFromAnotherMacsOlderCopy() {
        // Home was last reached an hour ago; work has since dropped the cancelled review.
        let home = snap([meeting("h1"), meeting("h2", "Dentist", at: 120)], at: -60)
        let workBefore = snap([meeting("w1"), meeting("w2", "Standup", at: 60)], at: -5)
        let workAfter = snap([meeting("w2", "Standup", at: 60)], at: -1)
        let dropped = DroppedMeeting.update([], macID: "work", old: workBefore, new: workAfter, now: now, cutoff: now - 86_400)
        #expect(dropped.map(\.meeting.id) == ["w1"])

        let agenda = MultiMacAgenda(agendas: [MacAgenda(macID: "work", snapshot: workAfter),
                                              MacAgenda(macID: "home", snapshot: home)], dropped: dropped)
        #expect(agenda.meetings.map(\.title) == ["Standup", "Dentist"])
        // The freshest copy, not the stalest, says when the agenda was brought up to date.
        #expect(agenda.updatedAt == workAfter.generatedAt)
    }

    @Test func aCopyMadeAfterTheDropStillShowsTheMeeting() {
        // Home saw the meeting after work dropped it (it's on a calendar only home has): it stays.
        let dropped = [DroppedMeeting(meeting: meeting("w1"), macID: "work", droppedAt: now.addingTimeInterval(-600))]
        let agenda = MultiMacAgenda(agendas: [MacAgenda(macID: "work", snapshot: snap([], at: -1)),
                                              MacAgenda(macID: "home", snapshot: snap([meeting("h1")], at: 0))], dropped: dropped)
        #expect(agenda.meetings.map(\.id) == ["h1"])
    }

    @Test func cancelledByTheOrganiserCountsAsDropped() {
        var cancelled = meeting("w1")
        cancelled.isCanceled = true
        let changes = DroppedMeeting.changes(from: snap([meeting("w1")], at: -5), to: snap([cancelled], at: -1), macID: "work", now: now)
        #expect(changes.map(\.meeting.id) == ["w1"])
        // The stale, uncancelled copy on the other Mac goes; the cancelled one stays as the Mac shows it.
        let agenda = MultiMacAgenda(agendas: [MacAgenda(macID: "work", snapshot: snap([cancelled], at: -1)),
                                              MacAgenda(macID: "home", snapshot: snap([meeting("h1")], at: -60))], dropped: changes)
        #expect(agenda.meetings.map(\.id) == ["w1"])
        #expect(agenda.meetings.first?.isCanceled == true)
    }

    @Test func reinvitedOrEndedMeetingsAreForgotten() {
        let dropped = [DroppedMeeting(meeting: meeting("w1"), macID: "work", droppedAt: now),
                       DroppedMeeting(meeting: meeting("old", at: -600), macID: "home", droppedAt: now)]
        let back = DroppedMeeting.update(dropped, macID: "work", old: snap([], at: 0), new: snap([meeting("w1")], at: 1),
                                         now: now, cutoff: now.addingTimeInterval(-3600))
        #expect(back.isEmpty)
        // Meetings already over aren't recorded at all.
        #expect(DroppedMeeting.changes(from: snap([meeting("past", at: -120)], at: 0), to: snap([], at: 1), macID: "work", now: now).isEmpty)
    }

    @Test func oneMacsOwnCopyIsNeverPrunedByItsOwnDrops() {
        let dropped = [DroppedMeeting(meeting: meeting("w1"), macID: "work", droppedAt: now.addingTimeInterval(600))]
        let agenda = MultiMacAgenda(agendas: [MacAgenda(macID: "work", snapshot: snap([meeting("w1")], at: 0))], dropped: dropped)
        #expect(agenda.meetings.map(\.id) == ["w1"])
    }

    @Test func droppedMeetingsRoundTrip() throws {
        let dropped = [DroppedMeeting(meeting: meeting("w1"), macID: "work", droppedAt: now)]
        let data = try JSONEncoder().encode(dropped)
        #expect(try JSONDecoder().decode([DroppedMeeting].self, from: data) == dropped)
    }
}
