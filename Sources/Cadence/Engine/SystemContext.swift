import AppKit
import CadenceCore
import CoreAudio

/// Reads what the Mac is doing right now: displays, presenting/sharing overlays and microphone use.
/// None of this needs extra permissions: window owner/bounds/layer are public without Screen Recording,
/// and CoreAudio reports which processes are capturing input.
@MainActor
enum SystemContext {
    static func current() -> AlertContext {
        let displays = displaySnapshots()
        let presenting = PresentationDetector.presentingDisplays(
            windows: windowSnapshots(),
            displays: displays,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        return AlertContext(displays: displays, presenting: presenting, microphoneApp: microphoneApp())
    }

    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for id: UInt32) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    // MARK: Displays & windows

    private static func displaySnapshots() -> [DisplaySnapshot] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let id = displayID(of: screen) else { return nil }
            return DisplaySnapshot(id: id, bounds: CGDisplayBounds(id), isMain: id == mainID)
        }
    }

    private static func windowSnapshots() -> [WindowSnapshot] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var bundleIDs: [Int32: String?] = [:]
        return raw.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            if bundleIDs[pid] == nil {
                bundleIDs[pid] = .some(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            }
            return WindowSnapshot(
                ownerPID: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                bundleID: bundleIDs[pid] ?? nil,
                layer: layer,
                bounds: bounds,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1
            )
        }
    }

    // MARK: Microphone

    /// Name of an app currently capturing audio input, e.g. "zoom.us" during a call.
    static func microphoneApp() -> String? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for process in audioObjects(kAudioHardwarePropertyProcessObjectList) {
            guard uint32(process, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            let pid = pid_t(bitPattern: uint32(process, kAudioProcessPropertyPID) ?? 0)
            guard pid != ownPID else { continue }
            let bundleID = string(process, kAudioProcessPropertyBundleID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            guard let bundleID, !ignoredMicBundlePrefixes.contains(where: bundleID.hasPrefix) else { continue }
            return appName(forBundleID: bundleID, pid: pid)
        }
        return nil
    }

    /// Background services that open the mic without a call (Siri, dictation, speech recognition).
    private static let ignoredMicBundlePrefixes = [
        "com.apple.siri", "com.apple.assistant", "com.apple.corespeech", "com.apple.SpeechRecognitionCore",
        "com.apple.dictation", "com.apple.accessibility", "com.apple.audio", "com.apple.coreaudio",
    ]

    /// Browsers capture audio in helper processes (e.g. com.google.Chrome.helper), so map back to the app.
    private static func appName(forBundleID bundleID: String, pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
            return app.localizedName ?? bundleID
        }
        let owner = NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
            return bundleID.hasPrefix(id + ".") || bundleID == id
        }
        return owner?.localizedName ?? bundleID
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }

    private static func audioObjects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// One-line description for Settings, e.g. "Presenting with Keynote on 1 display".
    static func describe(_ ctx: AlertContext) -> String {
        var parts: [String] = []
        if let first = ctx.presenting.first {
            let n = ctx.presenting.count
            parts.append("Presenting/sharing (\(first.appName)) on \(n) of \(ctx.displays.count) display\(ctx.displays.count == 1 ? "" : "s")")
        }
        if let mic = ctx.microphoneApp { parts.append("On a call — \(mic) is using the microphone") }
        return parts.isEmpty ? "Not presenting or on a call" : parts.joined(separator: " · ")
    }
}
