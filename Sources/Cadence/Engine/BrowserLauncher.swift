import AppKit
import CadenceCore
import Observation

/// The default browser and its profiles. Profile routing only ever targets the default browser;
/// when that's Safari (or anything else without profile support) links open as they always have.
@Observable
final class BrowserProfileStore {
    private(set) var defaultBrowser: ProfileBrowser?
    /// Name of the default browser even when it isn't supported ("Safari"), for Settings.
    private(set) var defaultBrowserName = ""
    private(set) var defaultBrowserURL: URL?
    /// The default browser's profiles, plus any Firefox containers the user added.
    private(set) var profiles: [BrowserProfile] = []

    @ObservationIgnored private var loadedAt: [String: Date] = [:]
    @ObservationIgnored private var containers: [FirefoxContainer] = []
    @ObservationIgnored private var baseProfiles: [BrowserProfile] = []

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    init() { refresh() }

    /// Re-reads the default browser and, if its profile list changed on disk, its profiles. Cheap.
    func refresh(containers: [FirefoxContainer]? = nil) {
        if let containers { self.containers = containers }
        let ws = NSWorkspace.shared
        let appURL = URL(string: "https://example.com").flatMap { ws.urlForApplication(toOpen: $0) }
        let bundle = appURL.flatMap { Bundle(url: $0) }
        let browser = bundle?.bundleIdentifier.flatMap(ProfileBrowser.init(bundleID:))
        let name = appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? ""

        if browser != defaultBrowser { loadedAt = [:] }
        if defaultBrowser != browser { defaultBrowser = browser }
        if defaultBrowserName != name { defaultBrowserName = name }
        if defaultBrowserURL != appURL { defaultBrowserURL = appURL }

        guard let browser else {
            if !profiles.isEmpty { profiles = [] }
            return
        }
        let file = Self.appSupport.appendingPathComponent(browser.profileListPath)
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        if modified == nil || loadedAt[file.path] != modified {
            baseProfiles = Self.load(browser, file: file)
            loadedAt[file.path] = modified
        }
        var list = baseProfiles
        if browser == .firefox {
            for c in self.containers {
                guard var p = baseProfiles.first(where: { $0.directory == c.profileDirectory }) else { continue }
                p.container = c.name
                list.append(p)
            }
        }
        if list != profiles { profiles = list }
    }

    private static func load(_ browser: ProfileBrowser, file: URL) -> [BrowserProfile] {
        if browser == .firefox {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return BrowserProfiles.parseFirefox(profilesINI: text, base: file.deletingLastPathComponent())
        }
        guard let data = try? Data(contentsOf: file) else { return [] }
        return BrowserProfiles.parseChromium(localState: data, browser: browser)
    }

    func profile(id: String?) -> BrowserProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    var supportsProfiles: Bool { defaultBrowser != nil && !profiles.isEmpty }

    var icon: NSImage? {
        defaultBrowserURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

enum BrowserLauncher {
    /// Opens `url` in `profile`, falling back to the default browser if anything goes wrong.
    static func open(_ url: URL, in profile: BrowserProfile) {
        let ws = NSWorkspace.shared
        guard let app = ws.urlForApplication(withBundleIdentifier: profile.browser.bundleID),
              let exe = Bundle(url: app)?.executableURL else {
            ws.open(url)
            return
        }
        let args = profile.launchArguments(for: url)
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: profile.browser.bundleID).isEmpty
        guard running else {
            // Not running: a normal launch delivers the arguments and keeps the browser independent of Cadence.
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = args
            config.activates = true
            ws.openApplication(at: app, configuration: config) { _, error in
                if error != nil { DispatchQueue.main.async { ws.open(url) } }
            }
            return
        }
        // Running: the browser's own executable hands the request to the running instance and exits.
        // It's run directly (no shell), so the URL is a single argument.
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSRunningApplication.runningApplications(withBundleIdentifier: profile.browser.bundleID).first?.activate()
            }
        } catch {
            ws.open(url)
        }
    }
}
