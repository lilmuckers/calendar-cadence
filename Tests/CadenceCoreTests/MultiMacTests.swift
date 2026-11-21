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
