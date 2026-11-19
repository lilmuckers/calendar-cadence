import Foundation
import Testing
@testable import CadenceCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Media remote control")
struct MediaRemoteTests {
    private func input(enabled: Bool = true, displaying: Bool = true, heardAgo: TimeInterval? = 2, onCall: Bool = false,
                       playing: Bool = true, stoppedAgo: TimeInterval? = nil, limit: TimeInterval? = 30) -> MediaRemoteGate.Input {
        .init(enabled: enabled, phoneDisplaying: displaying, lastHeard: heardAgo.map { now.addingTimeInterval(-$0) },
              onCall: onCall, phonePlaying: playing, phoneStoppedAt: stoppedAgo.map { now.addingTimeInterval(-$0) },
              pauseLimit: limit)
    }

    @Test func takesKeysWhilePhonePlaysInDeskMode() {
        #expect(MediaRemoteGate.intercepts(input(), now: now))
    }

    @Test func anythingMissingLeavesTheMacAlone() {
        #expect(!MediaRemoteGate.intercepts(input(enabled: false), now: now))
        #expect(!MediaRemoteGate.intercepts(input(displaying: false), now: now))
        #expect(!MediaRemoteGate.intercepts(input(heardAgo: nil), now: now))
        #expect(!MediaRemoteGate.intercepts(input(heardAgo: 20), now: now))
        #expect(!MediaRemoteGate.intercepts(input(onCall: true), now: now))
    }

    @Test func pauseLimit() {
        #expect(MediaRemoteGate.intercepts(input(playing: false, stoppedAgo: 10), now: now))
        #expect(!MediaRemoteGate.intercepts(input(playing: false, stoppedAgo: 31), now: now))
        #expect(!MediaRemoteGate.intercepts(input(playing: false, stoppedAgo: nil), now: now))
    }

    @Test func noPauseLimitKeepsTakingKeysInDeskMode() {
        #expect(MediaRemoteGate.intercepts(input(playing: false, stoppedAgo: nil, limit: nil), now: now))
        #expect(MediaRemoteGate.intercepts(input(playing: false, stoppedAgo: 3600, limit: nil), now: now))
        #expect(!MediaRemoteGate.intercepts(input(onCall: true, limit: nil), now: now))
    }

    @Test func volumeSteps() {
        #expect(MediaVolume.stepped(0.5, up: true) == 0.5625)
        #expect(MediaVolume.stepped(0.5, up: false) == 0.4375)
        #expect(MediaVolume.stepped(1, up: true) == 1)
        #expect(MediaVolume.stepped(0, up: false) == 0)
        // Off-grid levels (set by the phone's slider) snap to the nearest step first.
        #expect(MediaVolume.stepped(0.51, up: true) == 0.5625)
    }
}
