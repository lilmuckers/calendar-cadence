import AppKit
import CadenceCore
import UniformTypeIdentifiers

/// Export and import of every setting as a `.cadconf` file (YAML). Accounts, sign-ins, OAuth
/// tokens and client secrets, paired iPhones and remembered event state aren't settings
/// (they live in the Keychain or under their own keys), so they never go in the file.
@MainActor
enum SettingsTransfer {
    /// Declared in Info.plist (UTExportedTypeDeclarations), conforming to public.yaml.
    static let fileType = UTType(exportedAs: "com.cadence.calendarmonitor.settings", conformingTo: .yaml)

    /// The setting holding subscribed calendar links, which can be private ("secret address") URLs.
    private static let feedsKey = "icsFeeds"
    /// Setting that lets assistants act without asking; importing it is called out.
    private static let autoApproveKey = "mcpAutoApprove"

    /// Bigger than any real settings file.
    private static let maxFileSize = 1_000_000

    /// Remembered so an import can be undone from Settings.
    private(set) static var beforeLastImport: Preferences?

    // MARK: Export

    static func export(_ state: AppState) {
        let panel = NSSavePanel()
        panel.title = "Export Settings"
        panel.message = "Everything in Cadence's Settings. Accounts, sign-ins and paired iPhones aren't included."
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = "Cadence Settings.\(SettingsArchive.fileExtension)"
        panel.canCreateDirectories = true
        let includeFeeds = NSButton(checkboxWithTitle: "Include subscribed calendar (ICS) links", target: nil, action: nil)
        includeFeeds.state = .off
        includeFeeds.toolTip = "Off: the feeds you've added aren't exported, and importing the file keeps whatever feeds are already set up. Their links can be private addresses, so only include them in a file you'll keep to yourself."
        let accessory = NSStackView(views: [includeFeeds])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = accessory
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try fileText(state.prefs, includeFeeds: includeFeeds.state == .on)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("Couldn't export settings", error)
        }
    }

    static func fileText(_ prefs: Preferences, includeFeeds: Bool) throws -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let date = Date().formatted(date: .long, time: .shortened)
        return try SettingsArchive.export(prefs, omitting: includeFeeds ? [] : [feedsKey], comments: [
            "Cadence settings, exported \(date) from Cadence \(version).",
            "Import it in Cadence → Settings → General → Settings file, or double-click it.",
            "No accounts, sign-ins, tokens or paired iPhones are included."
                + (includeFeeds ? "" : " Subscribed calendar links were left out."),
            "Settings left out of the file keep their current value when it's imported.",
        ])
    }

    // MARK: Import

    static func chooseAndImport(_ state: AppState) {
        let panel = NSOpenPanel()
        panel.title = "Import Settings"
        panel.allowedContentTypes = [fileType, .yaml]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url, into: state)
    }

    /// Reads `url`, asks before replacing anything, then applies it.
    static func importFile(_ url: URL, into state: AppState) {
        let imported: SettingsArchive.Imported<Preferences>
        do {
            // Exports are a few kilobytes; don't read something huge into memory.
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileSize {
                throw CocoaError(.fileReadTooLarge)
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            imported = try SettingsArchive.read(text, over: state.prefs)
        } catch {
            fail("Couldn't import \(url.lastPathComponent)", error)
            return
        }
        let current = state.prefs
        let changes = changedKeys(from: current, to: imported.settings)
        NSApp.activate()
        guard !changes.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to change"
            alert.informativeText = "Every setting in \(url.lastPathComponent) already matches yours."
            alert.runModal()
            return
        }

        var notes = ["\(changes.count) \(changes.count == 1 ? "setting changes" : "settings change"). Accounts and sign-ins stay as they are."]
        if changes.contains(feedsKey) {
            notes.append("Your subscribed calendars are replaced with the \(imported.settings.icsFeeds.count) in the file.")
        }
        let newlyAllowed = imported.settings.mcpAutoApprove.subtracting(current.mcpAutoApprove)
        if !newlyAllowed.isEmpty {
            let names = newlyAllowed.map { MCPCatalog.tool($0)?.title ?? $0 }.sorted()
            notes.append("⚠️ It lets assistants do these without asking: \(names.joined(separator: ", ")).")
        }
        let alert = NSAlert()
        alert.messageText = "Import settings from \(url.lastPathComponent)?"
        alert.informativeText = notes.joined(separator: "\n\n")
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        beforeLastImport = current
        state.prefs = imported.settings
    }

    /// Puts back the settings from before the last import.
    static func undoImport(_ state: AppState) {
        guard let previous = beforeLastImport else { return }
        state.prefs = previous
        beforeLastImport = nil
    }

    /// Top-level settings whose value differs. Each is checked by putting just that one into
    /// `old` and comparing with `==`, so sets saved in a different order don't count as changes.
    private static func changedKeys(from old: Preferences, to new: Preferences) -> Set<String> {
        func object(_ p: Preferences) -> [String: Any] {
            (try? JSONEncoder().encode(p)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let a = object(old), b = object(new)
        return Set(a.keys).union(b.keys).filter { key in
            var one = a
            one[key] = b[key]
            guard JSONSerialization.isValidJSONObject(one), let data = try? JSONSerialization.data(withJSONObject: one),
                  let candidate = try? JSONDecoder().decode(Preferences.self, from: data) else { return true }
            return candidate != old
        }
    }

    private static func fail(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
