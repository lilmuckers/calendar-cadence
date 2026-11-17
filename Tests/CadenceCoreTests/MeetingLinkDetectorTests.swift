import Foundation
import Testing
@testable import CadenceCore

@Suite("Meeting link detection")
struct MeetingLinkDetectorTests {
    @Test("Recognises each service", arguments: [
        ("https://us02web.zoom.us/j/81234567890?pwd=abc123", MeetingService.zoom),
        ("https://zoom.us/my/someone", .zoom),
        ("https://company.zoomgov.com/j/1600000000", .zoom),
        ("zoommtg://zoom.us/join?confno=123", .zoom),
        ("https://meet.google.com/abc-defg-hij", .googleMeet),
        ("https://meet.google.com/abc-defg-hij?authuser=1", .googleMeet),
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZDk%40thread.v2/0?context=%7b%7d", .teams),
        ("https://teams.microsoft.com/meet/123456789?p=abc", .teams),
        ("https://teams.live.com/meet/9876543210", .teams),
        ("https://acme.webex.com/acme/j.php?MTID=m123", .webex),
        ("https://acme.webex.com/meet/jdoe", .webex),
        ("https://global.gotomeeting.com/join/123456789", .goToMeeting),
        ("https://meet.goto.com/123456789", .goToMeeting),
        ("https://whereby.com/team-room", .whereby),
        ("https://meet.jit.si/MyRoom", .jitsi),
        ("https://chime.aws/1234567890", .chime),
        ("https://app.slack.com/huddle/T123/C456", .slack),
        ("https://bluejeans.com/123456789", .blueJeans),
        ("https://join.skype.com/abcDEF", .skype),
        ("https://discord.gg/abc", .discord),
        ("https://facetime.apple.com/join#v=1&p=abc", .faceTime),
        ("https://tuple.app/c/abc", .tuple),
        ("https://v.ringcentral.com/join/123", .ringCentral),
    ])
    func services(url: String, expected: MeetingService) {
        let link = MeetingLinkDetector.firstMeetingLink(in: "Join: \(url) thanks")
        #expect(link?.service == expected)
        #expect(link?.url.absoluteString == url)
    }

    @Test func ignoresNonMeetingLinks() {
        #expect(MeetingLinkDetector.firstMeetingLink(in: "Agenda https://docs.google.com/doc/123 and https://zoom.us/pricing") == nil)
    }

    @Test func findsLinkInHTMLBody() {
        let body = #"<p>Hi</p><a href="https://meet.google.com/xyz-abcd-efg">Join with Google Meet</a>"#
        #expect(MeetingLinkDetector.detect(url: nil, location: nil, notes: body)?.service == .googleMeet)
    }

    @Test func decodesEntitiesInQuery() {
        let body = #"<a href="https://zoom.us/j/123?pwd=a&amp;uname=b">"#
        let link = MeetingLinkDetector.detect(url: nil, location: nil, notes: body)
        #expect(link?.url.absoluteString == "https://zoom.us/j/123?pwd=a&uname=b")
    }

    @Test func unwrapsOutlookSafeLinks() {
        let inner = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let wrapped = "https://nam12.safelinks.protection.outlook.com/?url=\(encoded)&data=05%7C01&reserved=0"
        let link = MeetingLinkDetector.detect(url: nil, location: nil, notes: "Click here <\(wrapped)>")
        #expect(link?.service == .teams)
        #expect(link?.url.absoluteString == inner)
    }

    @Test func unwrapsGoogleRedirect() {
        let wrapped = "https://www.google.com/url?q=https%3A%2F%2Fzoom.us%2Fj%2F555&sa=D"
        #expect(MeetingLinkDetector.detect(url: nil, location: nil, notes: wrapped)?.url.absoluteString == "https://zoom.us/j/555")
    }

    @Test func prefersURLFieldOverNotes() {
        let link = MeetingLinkDetector.detect(
            url: URL(string: "https://meet.google.com/aaa-bbbb-ccc"),
            location: nil,
            notes: "https://zoom.us/j/1"
        )
        #expect(link?.service == .googleMeet)
    }

    @Test func fallsBackToBareURLInLocation() {
        let link = MeetingLinkDetector.detect(url: nil, location: "https://example.com/room/7", notes: nil)
        #expect(link?.service == .other)
    }

    @Test func trimsTrailingPunctuation() {
        let link = MeetingLinkDetector.firstMeetingLink(in: "Use https://meet.google.com/abc-defg-hij.")
        #expect(link?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test func zoomNativeURL() {
        let link = MeetingLink(service: .zoom, url: URL(string: "https://us02web.zoom.us/j/8123?pwd=xyz")!)
        #expect(link.nativeURL?.absoluteString == "zoommtg://us02web.zoom.us/join?action=join&confno=8123&pwd=xyz")
    }

    @Test func teamsNativeURL() {
        let link = MeetingLink(service: .teams, url: URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!)
        #expect(link.nativeURL?.absoluteString == "msteams:/l/meetup-join/abc")
    }

    @Test func plainTextStripsTags() {
        #expect(MeetingLinkDetector.plainText("<p>Hello&nbsp;<b>there</b></p><br>Bye") == "Hello there\n\nBye")
    }
}

@Suite("Location classification")
struct LocationClassifierTests {
    @Test(arguments: ["1 Infinite Loop, Cupertino, CA", "Conference Room B", "Blue Bottle Coffee", "Zoom Room 4B, 12 Main St"])
    func physical(_ s: String) { #expect(LocationClassifier.isPhysical(s)) }

    @Test(arguments: ["Microsoft Teams Meeting", "https://zoom.us/j/1", "Zoom", "Google Meet", "", "Remote", "+1 555 123 4567"])
    func virtual(_ s: String) { #expect(!LocationClassifier.isPhysical(s)) }
}
