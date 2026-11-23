import AppKit
import CadenceCore
import CryptoKit
import Foundation
import Observation
import Security

/// Keeps Cadence up to date from the GitHub releases of its repository.
///
/// A release's `Cadence-X.Y.Z.zip` holds the notarized app. Before swapping it in, the updater checks
/// the zip against the release's `SHA256SUMS.txt` and the app's code signature against this app's own
/// Developer ID team. Builds without a team (ad-hoc local builds) can still check, but only offer a
/// download link. The swap itself runs in a small shell helper after Cadence quits, then reopens it.
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        /// Downloaded and verified, waiting for a quiet moment (automatic mode) or a click.
        case ready
        case installing
        case failed(String)
    }

    static let repository = "lilmuckers/calendar-cadence"
    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private static let lastRunKey = "Cadence.lastRunVersion"
    private static let notifiedKey = "Cadence.notifiedUpdate"

    /// The newest release newer than this build, once a check has found one.
    private(set) var available: GitHubRelease?
    private(set) var phase: Phase = .idle
    private(set) var lastChecked: Date?
    /// Every release from the last fetch, newest first (for the changelog).
    private(set) var releases: [GitHubRelease] = []

    /// Set by the app: the chosen mode (nil = not chosen yet, treated as off).
    @ObservationIgnored var mode: () -> UpdateMode? = { nil }
    /// Set by the app: true when restarting now wouldn't interrupt anything (no meeting on or close).
    @ObservationIgnored var isQuietMoment: () -> Bool = { true }
    /// A new version was found while in notify mode (once per version).
    @ObservationIgnored var onNewVersion: ((GitHubRelease) -> Void)?
    /// Opens the in-app window with what the available update brings.
    @ObservationIgnored var onShowNotes: (() -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var staged: (tag: String, app: URL)?
    @ObservationIgnored private let launched = Date()

    let current: SemVer? = SemVer(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
    /// This build's Developer ID team, nil for ad-hoc builds.
    let teamID: String? = Updater.runningTeamID()

    var currentVersionText: String { current?.description ?? "dev" }

    /// Whether this copy can replace itself: signed by a team, and its folder is writable
    /// (not a disk image, not App Translocation).
    var canInstall: Bool {
        guard teamID != nil, current != nil else { return false }
        let app = Bundle.main.bundleURL
        let fm = FileManager.default
        return fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: app.path)
    }

    /// Why installing isn't possible, for Settings and the menu.
    var cannotInstallReason: String? {
        if current == nil { return "This is a development build without a version." }
        if teamID == nil { return "This build isn't signed with a Developer ID, so it can't update itself. Download the new version instead." }
        if !canInstall { return "Cadence can't write to the folder it's in. Move it to Applications, or download the new version." }
        return nil
    }

    // MARK: - Schedule

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // First look shortly after launch, once the calendars are in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard let mode = mode(), mode != .off else { return }
        // A failed check (offline, say) tries again after half an hour.
        let interval = isFailed ? 30 * 60 : Self.checkInterval
        if phase == .idle || isFailed,
           lastChecked.map({ Date().timeIntervalSince($0) > interval }) ?? (Date().timeIntervalSince(launched) >= 25) {
            Task { await check() }
        }
        if mode == .automatic, phase == .ready, let staged, isQuietMoment() {
            relaunch(into: staged.app)
        }
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    // MARK: - Checking

    /// Looks for a newer release. In automatic mode it then downloads it straight away.
    func check() async {
        guard phase != .checking, phase != .downloading, phase != .installing else { return }
        phase = .checking
        do {
            releases = try await fetchReleases()
            lastChecked = Date()
            available = current.flatMap { UpdatePlanner.newest(in: releases, newerThan: $0) }
            if staged != nil, staged?.tag == available?.tag {
                phase = .ready
            } else {
                phase = .idle
            }
        } catch {
            lastChecked = Date()
            phase = .failed("Couldn't check for updates: \(error.localizedDescription)")
            return
        }
        guard let available, phase == .idle else { return }
        switch mode() {
        case .automatic where canInstall:
            await download(available)
        case .notify, .automatic:
            let notified = UserDefaults.standard.string(forKey: Self.notifiedKey)
            if notified != available.tag {
                UserDefaults.standard.set(available.tag, forKey: Self.notifiedKey)
                onNewVersion?(available)
            }
        default:
            break
        }
    }

    func fetchReleases() async throws -> [GitHubRelease] {
        let repo = Bundle.main.infoDictionary?["CadenceUpdateRepo"] as? String ?? Self.repository
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cadence-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub answered \(http.statusCode)")
        }
        return try GitHubRelease.decodeList(data)
    }

    // MARK: - Installing

    /// Download, verify and restart into the newest version (the "Update" button).
    func installAvailable() {
        guard let available else { return }
        guard canInstall else { NSWorkspace.shared.open(available.page); return }
        Task {
            if staged?.tag != available.tag { await download(available) }
            if phase == .ready, let staged { relaunch(into: staged.app) }
        }
    }

    private func download(_ release: GitHubRelease) async {
        phase = .downloading
        do {
            staged = (release.tag, try await fetchAndVerify(release))
            phase = .ready
        } catch {
            phase = .failed("Couldn't download \(release.tag): \(error.localizedDescription)")
        }
    }

    private func fetchAndVerify(_ release: GitHubRelease) async throws -> URL {
        guard let zip = UpdatePlanner.zipAsset(release), let sums = UpdatePlanner.checksumsAsset(release) else {
            throw UpdateError("the release has no app download")
        }
        let fm = FileManager.default
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = caches.appending(path: Bundle.main.bundleIdentifier ?? "Cadence").appending(path: "Updates")
        try? fm.removeItem(at: root) // older attempts
        let folder = root.appending(path: release.tag)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let (sumsData, _) = try await URLSession.shared.data(from: sums.url)
        guard let expected = UpdatePlanner.parseChecksums(String(decoding: sumsData, as: UTF8.self))[zip.name] else {
            throw UpdateError("no checksum for \(zip.name)")
        }
        let (downloaded, _) = try await URLSession.shared.download(from: zip.url)
        let zipURL = folder.appending(path: zip.name)
        try fm.moveItem(at: downloaded, to: zipURL)
        let digest = try await Task.detached { try SHA256.hash(data: Data(contentsOf: zipURL, options: .mappedIfSafe)) }.value
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == expected else { throw UpdateError("the download didn't match its checksum") }

        try await Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, folder.path])
        let app = folder.appending(path: "Cadence.app")
        guard fm.fileExists(atPath: app.path) else { throw UpdateError("the download had no Cadence.app") }
        guard let teamID else { throw UpdateError("this build can't verify updates") }
        try Self.verifySignature(of: app, teamID: teamID)
        let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard SemVer(version ?? "") == release.version else { throw UpdateError("the download is a different version") }
        return app
    }

    /// Quits and swaps the new app in place of this one, then opens it.
    private func relaunch(into newApp: URL) {
        phase = .installing
        let script = """
        pid="$1"; old="$2"; new="$3"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        backup="$old.updating-$$"
        if mv "$old" "$backup"; then
          if mv "$new" "$old"; then rm -rf "$backup"; else mv "$backup" "$old"; fi
        fi
        xattr -dr com.apple.quarantine "$old" 2>/dev/null
        open "$old"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "cadence-update",
                            String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path, newApp.path]
        do {
            try helper.run()
        } catch {
            phase = .failed("Couldn't start the update: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - What's new

    func showNotes() { onShowNotes?() }

    /// The version the previous launch ran, or nil on the very first launch. Records this one.
    func recordLaunch() -> SemVer? {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.lastRunKey).flatMap(SemVer.init)
        if let current { defaults.set(current.description, forKey: Self.lastRunKey) }
        return previous
    }

    // MARK: - Signatures

    private static func runningTeamID() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamID(of: staticCode)
    }

    private static func teamID(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The new app must be validly signed by the same Developer ID team, with the same identifier.
    private static func verifySignature(of app: URL, teamID: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("the download isn't a signed app")
        }
        let identifier = Bundle.main.bundleIdentifier ?? "com.cadence.calendarmonitor"
        let text = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("couldn't build the signature check")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError("the download isn't signed by the same developer (\(status))")
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
            p.terminationHandler = { p in
                if p.terminationStatus == 0 { done.resume() } else { done.resume(throwing: UpdateError("\(tool) failed (\(p.terminationStatus))")) }
            }
            do { try p.run() } catch { done.resume(throwing: error) }
        }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
