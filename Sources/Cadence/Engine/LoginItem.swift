import AppKit
import ServiceManagement

/// Launch at login, with errors put in plain words. Shared by Settings → General and setup.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns launch at login on or off. Returns what went wrong, if anything, in words for the user.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            return on
                ? "macOS wouldn't add Cadence to your login items. Move Cadence to Applications and try again, or add it in System Settings → Login Items."
                : "macOS wouldn't remove Cadence from your login items. Remove it in System Settings → Login Items."
        }
        if on, SMAppService.mainApp.status == .requiresApproval {
            return "Allow Cadence in System Settings → Login Items to finish."
        }
        return nil
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
