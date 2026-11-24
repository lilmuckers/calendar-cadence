import Foundation
import Testing
@testable import CadenceCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func running(bluetoothAllowed: Bool = true) -> TransportPlanner {
    var p = TransportPlanner(bluetoothAllowed: bluetoothAllowed)
    p.start()
    p.pathChanged(hasLocalNetwork: true, now: t0)
    return p
}

@Suite("Transport planner")
struct TransportPlannerTests {
    // MARK: Network first

    @Test func bluetoothNeverStartsWhileTheNetworkIsUntried() {
        let p = running()
        #expect(!p.wantsBluetooth(now: t0))
        #expect(!p.wantsBluetooth(now: t0.addingTimeInterval(3600)))
        #expect(p.nextDeadline(after: t0) == nil)
    }

    @Test func failedNetworkRoundFallsBack() {
        var p = running()
        p.networkRoundFailedToConnect()
        #expect(p.wantsBluetooth(now: t0))
    }

    @Test func noWiFiFallsBackAfterGrace() {
        var p = running()
        p.pathChanged(hasLocalNetwork: false, now: t0)
        #expect(!p.wantsBluetooth(now: t0.addingTimeInterval(TransportPlanner.grace - 0.1)))
        #expect(p.nextDeadline(after: t0) == t0.addingTimeInterval(TransportPlanner.grace))
        #expect(p.wantsBluetooth(now: t0.addingTimeInterval(TransportPlanner.grace)))
    }

    @Test func wiFiBackWithinGraceNeverFallsBack() {
        var p = running()
        p.pathChanged(hasLocalNetwork: false, now: t0)
        p.pathChanged(hasLocalNetwork: true, now: t0.addingTimeInterval(1))
        #expect(!p.wantsBluetooth(now: t0.addingTimeInterval(10)))
    }

    @Test func deniedLocalNetworkFallsBackAfterGrace() {
        var p = running()
        p.localNetworkAccess(denied: true, now: t0)
        #expect(!p.wantsBluetooth(now: t0.addingTimeInterval(1)))
        #expect(p.wantsBluetooth(now: t0.addingTimeInterval(TransportPlanner.grace)))
    }

    @Test func joiningANetworkGivesItAFreshRoundFirst() {
        var p = running()
        p.pathChanged(hasLocalNetwork: false, now: t0)
        p.networkRoundFailedToConnect()
        #expect(p.wantsBluetooth(now: t0.addingTimeInterval(5)))
        // Onto Wi-Fi, Bluetooth not connected yet: try the network before Bluetooth again.
        p.pathChanged(hasLocalNetwork: true, now: t0.addingTimeInterval(6))
        #expect(!p.wantsBluetooth(now: t0.addingTimeInterval(6)))
    }

    @Test func grantingLocalNetworkGivesItAFreshRound() {
        var p = running()
        p.localNetworkAccess(denied: true, now: t0)
        p.networkRoundFailedToConnect()
        p.localNetworkAccess(denied: false, now: t0.addingTimeInterval(10))
        #expect(!p.wantsBluetooth(now: t0.addingTimeInterval(10)))
    }

    @Test func restartingGivesTheNetworkAFreshRound() {
        var p = running()
        p.networkRoundFailedToConnect()
        p.stop()
        p.start()
        #expect(!p.wantsBluetooth(now: t0))
    }

    // MARK: Moving back to the network

    @Test func networkConnectionStopsBluetooth() {
        var p = running()
        p.networkRoundFailedToConnect()
        p.connected(.network)
        #expect(!p.wantsBluetooth(now: t0))
        #expect(!p.shouldDropBluetooth)
    }

    @Test func networkReplacesABluetoothChannel() {
        var p = running()
        p.networkRoundFailedToConnect()
        p.connected(.bluetooth)
        #expect(p.wantsBluetooth(now: t0))
        p.connected(.network)
        #expect(p.shouldDropBluetooth)
        #expect(!p.wantsBluetooth(now: t0))
        p.disconnected(.bluetooth)
        #expect(!p.shouldDropBluetooth)
        #expect(p.connected == [.network])
    }

    @Test func bluetoothThatConnectsAfterTheNetworkIsDropped() {
        var p = running()
        p.networkRoundFailedToConnect()
        p.connected(.network)
        // A Bluetooth attempt that was already under way finishes late.
        p.connected(.bluetooth)
        #expect(p.shouldDropBluetooth)
    }

    @Test func bluetoothStaysWhenWiFiReturnsUntilTheNetworkConnects() {
        var p = running()
        p.pathChanged(hasLocalNetwork: false, now: t0)
        p.connected(.bluetooth)
        p.pathChanged(hasLocalNetwork: true, now: t0.addingTimeInterval(30))
        // Don't drop a working link just because Wi-Fi is back: wait for a network channel.
        #expect(p.wantsBluetooth(now: t0.addingTimeInterval(30)))
        #expect(!p.shouldDropBluetooth)
    }

    @Test func losingTheNetworkLinkTriesTheNetworkFirstAgain() {
        var p = running()
        p.networkRoundFailedToConnect()
        p.connected(.network)
        p.disconnected(.network)
        #expect(!p.wantsBluetooth(now: t0))
        p.networkRoundFailedToConnect()
        #expect(p.wantsBluetooth(now: t0))
    }

    @Test func losingBluetoothKeepsFallingBack() {
        var p = running()
        p.networkRoundFailedToConnect()
        p.connected(.bluetooth)
        p.disconnected(.bluetooth)
        // The network still hasn't worked, so look for the Mac over Bluetooth again.
        #expect(p.wantsBluetooth(now: t0))
    }

    // MARK: Off switches

    @Test func bluetoothOffMeansNetworkOnly() {
        var p = running(bluetoothAllowed: false)
        p.networkRoundFailedToConnect()
        p.pathChanged(hasLocalNetwork: false, now: t0)
        #expect(!p.wantsBluetooth(now: t0.addingTimeInterval(60)))
        #expect(p.nextDeadline(after: t0) == nil)
    }

    @Test func stoppedLinkWantsNothing() {
        var p = running()
        p.networkRoundFailedToConnect()
        p.connected(.bluetooth)
        p.stop()
        #expect(!p.wantsBluetooth(now: t0))
        #expect(p.connected.isEmpty)
        p.networkRoundFailedToConnect()
        #expect(!p.wantsBluetooth(now: t0))
    }
}
