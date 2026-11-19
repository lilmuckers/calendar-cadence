import AppKit
import ApplicationServices
import CadenceCore

/// The keyboard's media keys (volume, mute, play/pause, next, previous), caught before macOS acts
/// on them so they can go to the phone instead. Each key is decided on the spot by `shouldIntercept`;
/// whenever that says no, the key carries on to the Mac untouched.
///
/// Needs Accessibility access (System Settings → Privacy & Security → Accessibility). macOS ties
/// that to the app's signature, so a rebuild signed differently loses it and the tap stops working
/// until it's granted again; the keys then simply work as normal on the Mac.
@MainActor
final class MediaKeyTap {
    enum Key: Int32 {
        // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
        case volumeUp = 0, volumeDown = 1, mute = 7, play = 16, next = 17, previous = 18

        var command: MediaCommand {
            switch self {
            case .volumeUp: .volumeUp
            case .volumeDown: .volumeDown
            case .mute: .toggleMute
            case .play: .togglePlayPause
            case .next: .next
            case .previous: .previous
            }
        }
    }

    /// Asked for every media key press: true sends it to `onKey` and hides it from the Mac.
    var shouldIntercept: () -> Bool = { false }
    /// A key going down (and repeating, for volume) while intercepting.
    var onKey: (Key) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys whose press we took, so their release is taken too (whatever's changed since).
    private var held: Set<Int32> = []

    var isRunning: Bool { tap != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow Accessibility" prompt (once; after that it's System Settings).
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Starts or stops the tap to match `wanted`. Called regularly, so access granted later picks up.
    func update(wanted: Bool) {
        if wanted, tap == nil, Self.isTrusted { start() }
        if !wanted, tap != nil { stop() }
    }

    private func start() {
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED: media keys arrive as system-defined events
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: refcon) else {
            NSLog("Cadence: couldn't start the media key tap (Accessibility access?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        NSLog("Cadence: media key tap on")
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        held = []
        NSLog("Cadence: media key tap off")
    }

    /// Back on after macOS switched it off (it does if a callback is ever too slow).
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns nil to swallow the event, or the event to let it through.
    fileprivate func handle(_ event: CGEvent) -> CGEvent? {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return event }
        let code = Int32((ns.data1 & 0xFFFF_0000) >> 16)
        guard let key = Key(rawValue: code) else { return event }
        let flags = ns.data1 & 0xFFFF
        let down = ((flags & 0xFF00) >> 8) == 0xA
        let isRepeat = flags & 0x1 == 1
        if !down {
            return held.remove(code) != nil ? nil : event
        }
        guard held.contains(code) || shouldIntercept() else { return event }
        held.insert(code)
        // Holding volume repeats; holding play/skip shouldn't fire over and over.
        if !isRepeat || key == .volumeUp || key == .volumeDown { onKey(key) }
        return nil
    }

    // MARK: Conflicts

    /// Apps known to catch or remap media keys, by bundle ID prefix.
    private static let knownRemappers: [(prefix: String, name: String)] = [
        ("org.pqrs.Karabiner", "Karabiner-Elements"),
        ("com.hegenberg.BetterTouchTool", "BetterTouchTool"),
        ("org.hammerspoon.Hammerspoon", "Hammerspoon"),
        ("com.stairways.keyboardmaestro", "Keyboard Maestro"),
        ("com.beardedspice", "BeardedSpice"),
        ("com.milgra.hsmke", "Mac Media Key Forwarder"),
        ("me.guillaumeb.MonitorControl", "MonitorControl"),
        ("com.rogueamoeba.soundsource", "SoundSource"),
        ("com.bitgapp.eqmac", "eqMac"),
        ("digital.twisted.noTunes", "noTunes"),
    ]

    /// Other apps that could get to the media keys first (or after us): known remappers that are
    /// running, plus any other app with an event tap on media keys.
    static func conflicts() -> [String] {
        var names: [String] = []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier,
                  let known = knownRemappers.first(where: { id.lowercased().hasPrefix($0.prefix.lowercased()) }) else { continue }
            if !names.contains(known.name) { names.append(known.name) }
        }
        // Event taps on system-defined events (media keys) belonging to other, non-Apple apps.
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return names }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return names }
        for info in taps.prefix(Int(count)) where info.enabled && info.eventsOfInterest & (CGEventMask(1) << 14) != 0 {
            let pid = pid_t(info.tappingProcess)
            guard pid != ownPID, let app = NSRunningApplication(processIdentifier: pid),
                  let id = app.bundleIdentifier, !id.hasPrefix("com.apple.") else { continue }
            let name = app.localizedName ?? id
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    // The tap's run loop source is on the main run loop, so this runs on the main thread.
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tap.reenable()
            return Unmanaged.passUnretained(event)
        }
        return tap.handle(event).map { Unmanaged.passUnretained($0) }
    }
}
