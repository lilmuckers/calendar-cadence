import CoreGraphics
import Foundation

/// A window as reported by the window server, reduced to what presentation detection needs.
/// Coordinates are global, top-left origin (Quartz), matching `CGDisplayBounds`.
public struct WindowSnapshot: Equatable, Sendable {
    public var ownerPID: Int32
    public var ownerName: String
    public var bundleID: String?
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double

    public init(ownerPID: Int32, ownerName: String, bundleID: String?, layer: Int, bounds: CGRect, alpha: Double = 1) {
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.bundleID = bundleID
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }
}

public struct DisplaySnapshot: Equatable, Sendable {
    public var id: UInt32
    public var bounds: CGRect
    public var isMain: Bool

    public init(id: UInt32, bounds: CGRect, isMain: Bool) {
        self.id = id
        self.bounds = bounds
        self.isMain = isMain
    }
}

/// Why a display counts as "presenting", for the Settings diagnostic.
public struct PresentingDisplay: Hashable, Sendable {
    public var displayID: UInt32
    public var appName: String
}

public enum PresentationDetector {
    /// Slideshow apps whose full-screen windows count even at the normal window layer.
    public static let presentationBundleIDs: Set<String> = [
        "com.apple.iWork.Keynote",
        "com.microsoft.Powerpoint",
        "com.apple.Preview", // Preview slideshow
    ]

    /// System processes with full-screen overlays that never mean "presenting".
    public static let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center", "Control Centre",
        "Notification Center", "Notification Centre", "WindowManager", "loginwindow",
        "Spotlight", "screencaptureui", "TextInputMenuAgent", "ScreenSaverEngine",
    ]

    /// A display is "presenting" when another app covers (almost) all of it with a window
    /// floating above normal windows — Keynote/PowerPoint slideshows, and the coloured
    /// border Zoom/Teams draw around a shared screen — or when a slideshow app fills it.
    public static func presentingDisplays(
        windows: [WindowSnapshot],
        displays: [DisplaySnapshot],
        ownPID: Int32,
        coverage: Double = 0.9
    ) -> [PresentingDisplay] {
        var result: [PresentingDisplay] = []
        for display in displays {
            let area = display.bounds.width * display.bounds.height
            guard area > 0 else { continue }
            let hit = windows.first { w in
                guard w.ownerPID != ownPID, w.alpha > 0.01, !ignoredOwners.contains(w.ownerName) else { return false }
                let isSlideshowApp = w.bundleID.map(presentationBundleIDs.contains) ?? false
                guard w.layer > 0 || (isSlideshowApp && w.layer == 0) else { return false }
                let overlap = w.bounds.intersection(display.bounds)
                guard !overlap.isNull else { return false }
                return Double(overlap.width * overlap.height) / Double(area) >= coverage
            }
            if let hit { result.append(PresentingDisplay(displayID: display.id, appName: hit.ownerName)) }
        }
        return result
    }
}

/// What to do when an alert fires while the user is busy.
public enum BusyAlertStyle: String, Codable, CaseIterable, Sendable {
    /// Full-screen alert, but never on a display that is being presented or shared.
    case fullScreen
    /// Small non-focus-stealing banner.
    case banner
    /// macOS notification (hidden automatically while sharing/mirroring).
    case notification
    /// No alert at all.
    case skip

    public var label: String {
        switch self {
        case .fullScreen: "Full-screen on other displays"
        case .banner: "Small banner"
        case .notification: "Notification only"
        case .skip: "Don't alert"
        }
    }
}

/// The system situation at the moment an alert fires.
public struct AlertContext: Sendable {
    public var displays: [DisplaySnapshot]
    public var presenting: [PresentingDisplay]
    /// Name of the app using the microphone, if any.
    public var microphoneApp: String?

    public init(displays: [DisplaySnapshot], presenting: [PresentingDisplay] = [], microphoneApp: String? = nil) {
        self.displays = displays
        self.presenting = presenting
        self.microphoneApp = microphoneApp
    }

    public var isPresenting: Bool { !presenting.isEmpty }
    public var isOnCall: Bool { microphoneApp != nil }
}

/// How an alert should be shown.
public enum AlertPlan: Equatable, Sendable {
    case fullScreen(displays: [UInt32])
    case banner(displays: [UInt32])
    case notification
    case none
}

public enum AlertPolicy {
    public static func plan(
        context: AlertContext,
        allScreens: Bool,
        whilePresenting: BusyAlertStyle,
        whileOnCall: BusyAlertStyle
    ) -> AlertPlan {
        let presentingIDs = Set(context.presenting.map(\.displayID))
        let free = context.displays.filter { !presentingIDs.contains($0.id) }
        let main = context.displays.first(where: \.isMain) ?? context.displays.first

        let style: BusyAlertStyle
        if context.isPresenting {
            style = whilePresenting
        } else if context.isOnCall {
            style = whileOnCall
        } else {
            let targets = allScreens ? context.displays : [main].compactMap { $0 }
            return targets.isEmpty ? .notification : .fullScreen(displays: targets.map(\.id))
        }

        // Prefer the main display when it's free; otherwise any free display.
        let freeMain = free.first(where: \.isMain) ?? free.first
        switch style {
        case .skip:
            return .none
        case .notification:
            return .notification
        case .fullScreen:
            let targets = allScreens ? free : [freeMain].compactMap { $0 }
            return targets.isEmpty ? .notification : .fullScreen(displays: targets.map(\.id))
        case .banner:
            guard let target = freeMain else { return .notification }
            return .banner(displays: [target.id])
        }
    }
}
