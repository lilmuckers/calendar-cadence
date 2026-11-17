import CoreGraphics
import Testing
@testable import CadenceCore

private let main = DisplaySnapshot(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), isMain: true)
private let side = DisplaySnapshot(id: 2, bounds: CGRect(x: 1512, y: -200, width: 2560, height: 1440), isMain: false)
private let ownPID: Int32 = 999

private func window(_ owner: String, bundle: String? = nil, layer: Int, on rect: CGRect, pid: Int32 = 42, alpha: Double = 1) -> WindowSnapshot {
    WindowSnapshot(ownerPID: pid, ownerName: owner, bundleID: bundle, layer: layer, bounds: rect, alpha: alpha)
}

@Suite("Presentation detection")
struct PresentationDetectorTests {
    @Test func normalWindowsAreNotPresenting() {
        let windows = [
            window("Safari", layer: 0, on: main.bounds), // regular full-screen app
            window("Slack", layer: 0, on: CGRect(x: 100, y: 100, width: 800, height: 600)),
        ]
        #expect(PresentationDetector.presentingDisplays(windows: windows, displays: [main, side], ownPID: ownPID).isEmpty)
    }

    @Test func keynoteSlideshowAtNormalLayer() {
        let windows = [window("Keynote", bundle: "com.apple.iWork.Keynote", layer: 0, on: side.bounds)]
        let result = PresentationDetector.presentingDisplays(windows: windows, displays: [main, side], ownPID: ownPID)
        #expect(result == [PresentingDisplay(displayID: 2, appName: "Keynote")])
    }

    @Test func sharingBorderOverlay() {
        // Teams/Zoom draw a coloured border window over the shared display at a raised layer.
        let windows = [window("Microsoft Teams", layer: 25, on: main.bounds.insetBy(dx: -2, dy: -2))]
        let result = PresentationDetector.presentingDisplays(windows: windows, displays: [main, side], ownPID: ownPID)
        #expect(result.map(\.displayID) == [1])
    }

    @Test func ignoresSmallFloatingWindowsSystemAndSelf() {
        let windows = [
            window("zoom.us", layer: 3, on: CGRect(x: 10, y: 10, width: 320, height: 180)),
            window("Dock", layer: 20, on: main.bounds),
            window("Window Server", layer: 24, on: main.bounds),
            window("Cadence", layer: 1000, on: main.bounds, pid: ownPID),
            window("Invisible", layer: 25, on: main.bounds, alpha: 0),
        ]
        #expect(PresentationDetector.presentingDisplays(windows: windows, displays: [main], ownPID: ownPID).isEmpty)
    }
}

@Suite("Alert policy")
struct AlertPolicyTests {
    private func plan(_ ctx: AlertContext, all: Bool = true, presenting: BusyAlertStyle = .banner, call: BusyAlertStyle = .banner) -> AlertPlan {
        AlertPolicy.plan(context: ctx, allScreens: all, whilePresenting: presenting, whileOnCall: call)
    }

    @Test func idleCoversAllOrMain() {
        let ctx = AlertContext(displays: [main, side])
        #expect(plan(ctx) == .fullScreen(displays: [1, 2]))
        #expect(plan(ctx, all: false) == .fullScreen(displays: [1]))
    }

    @Test func presentingAvoidsPresentedDisplay() {
        let ctx = AlertContext(displays: [main, side], presenting: [PresentingDisplay(displayID: 1, appName: "Keynote")])
        #expect(plan(ctx) == .banner(displays: [2]))
        #expect(plan(ctx, presenting: .fullScreen) == .fullScreen(displays: [2]))
        #expect(plan(ctx, presenting: .notification) == .notification)
        #expect(plan(ctx, presenting: .skip) == AlertPlan.none)
    }

    @Test func everyDisplayPresentedFallsBackToNotification() {
        let ctx = AlertContext(displays: [main], presenting: [PresentingDisplay(displayID: 1, appName: "Keynote")])
        #expect(plan(ctx) == .notification)
        #expect(plan(ctx, presenting: .fullScreen) == .notification)
    }

    @Test func onCallUsesCallStyle() {
        let ctx = AlertContext(displays: [main, side], microphoneApp: "zoom.us")
        #expect(plan(ctx) == .banner(displays: [1]))
        #expect(plan(ctx, call: .fullScreen) == .fullScreen(displays: [1, 2]))
        #expect(plan(ctx, call: .skip) == AlertPlan.none)
    }

    @Test func presentingWinsOverCall() {
        let ctx = AlertContext(displays: [main, side], presenting: [PresentingDisplay(displayID: 1, appName: "Teams")], microphoneApp: "Teams")
        #expect(plan(ctx, presenting: .skip, call: .fullScreen) == AlertPlan.none)
    }
}
