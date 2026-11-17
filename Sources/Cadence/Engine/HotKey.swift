import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A recorded keyboard shortcut.
struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt // NSEvent.ModifierFlags raw value (device-independent bits)
    var key: String     // display character, e.g. "J"

    static let defaultJoin = HotKeySpec(
        keyCode: UInt32(kVK_ANSI_J),
        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue,
        key: "J"
    )

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

/// System-wide hotkey via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func register(_ spec: HotKeySpec?) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let spec else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4344_4E43), id: 1) // 'CDNC'
        let status = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("Cadence: hotkey \(spec.display) unavailable (\(status))") }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.action?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Click, then press a key combination. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var spec: HotKeySpec?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press shortcut…" : (spec?.display ?? "Record Shortcut"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
            }
            if spec != nil && !recording {
                Button { spec = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        // Release the current hotkey while recording so pressing it doesn't fire the action.
        GlobalHotKey.shared.register(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                spec = nil
                stop()
            default:
                // Require at least one of ⌘⌥⌃ so plain typing never becomes a global shortcut.
                guard !mods.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
                let key = (event.charactersIgnoringModifiers ?? "?").uppercased()
                spec = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue, key: key == " " ? "Space" : key)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            GlobalHotKey.shared.register(spec)
        }
    }
}
