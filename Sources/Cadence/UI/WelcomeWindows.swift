import AppKit
import CadenceCore
import SwiftUI

/// First-launch setup (also from Settings → General → Run Setup Again) and the "What's new" screen
/// shown on the first launch after an update. Plain windows, since a menu-bar app has no SwiftUI
/// `openWindow` until its menu has been opened.
@MainActor
final class WelcomeWindows: NSObject, NSWindowDelegate {
    private let state: AppState
    private var window: NSWindow?
    private var setupWindow: NSWindow?

    init(state: AppState) { self.state = state }

    func showSetup() {
        if let setupWindow, setupWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            setupWindow.makeKeyAndOrderFront(nil)
            return
        }
        present(title: "Set Up Cadence", width: SetupView.width) { [state] close in
            SetupView(finish: close).environment(state)
        }
        setupWindow = window
        window?.delegate = self
    }

    /// Closing setup early, however it's closed, counts as done: what's left goes to the menu's checklist.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === setupWindow else { return }
        MenuBarPointer.shared.hide()
        if state.prefs.updateMode == nil { state.prefs.updateMode = .notify }
        setupWindow = nil
        Task { await state.refreshNotificationStatus() }
    }

    func showWhatsNew(from previous: SemVer?) {
        let updater = state.updater
        guard let current = updater.current else { return }
        Task {
            let releases = (try? await updater.fetchReleases()) ?? []
            let log = UpdatePlanner.changelog(releases, from: previous, to: current)
            present(title: "What's New in Cadence", width: 520) { close in
                ChangelogView(purpose: .updated(current), releases: log, done: close)
            }
        }
    }

    /// What the available update brings, with the button that installs it.
    func showAvailable() {
        let updater = state.updater
        guard let release = updater.available, let new = release.version else { return }
        Task {
            var releases = updater.releases
            if releases.isEmpty { releases = (try? await updater.fetchReleases()) ?? [] }
            let log = UpdatePlanner.changelog(releases, from: updater.current, to: new)
            present(title: "Cadence Update", width: 520) { close in
                ChangelogView(purpose: .available(release, updater), releases: log, done: close)
            }
        }
    }

    private func present<Content: View>(title: String, width: CGFloat, @ViewBuilder _ content: (@escaping () -> Void) -> Content) {
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let close: () -> Void = { [weak window] in window?.close() }
        let host = NSHostingView(rootView: content(close)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .ignoresSafeArea()
            .background(.background))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Release notes in the app: "What's new" after an update, or what an available update brings.
struct ChangelogView: View {
    enum Purpose {
        /// Just updated to this version.
        case updated(SemVer)
        /// This release is available; the updater installs it.
        case available(GitHubRelease, Updater)
    }

    let purpose: Purpose
    let releases: [GitHubRelease]
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MascotHeader(mood: isAvailable ? .nervous : .calm, height: 130)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [AboutMascot.pink, AboutMascot.orange],
                                                        startPoint: .leading, endPoint: .trailing))
                    Text(subtitle)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if MenuBarView.screenshotMode {
                    notes // ImageRenderer can't draw ScrollView contents.
                } else {
                    ScrollView { notes }.frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
                }
                buttons
            }
            .padding(22)
        }
        .background(.background)
    }

    private var isAvailable: Bool { if case .available = purpose { true } else { false } }

    private var title: String {
        switch purpose {
        case .updated(let version): "Updated to \(version)"
        case .available(let release, _): "Cadence \(release.version?.description ?? release.tag) is out"
        }
    }

    private var subtitle: String {
        let count = releases.count
        switch purpose {
        case .updated:
            return count > 1 ? "Here's what changed in the last \(count) releases." : "Here's what changed."
        case .available(_, let updater):
            let since = "You have \(updater.currentVersionText)"
            return count > 1 ? "\(since). Here's what the \(count) releases since then bring." : "\(since). Here's what it brings."
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            if releases.isEmpty {
                Text("Couldn't load the release notes.")
                    .foregroundStyle(.secondary)
            }
            ForEach(releases) { ReleaseCard(release: $0) }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            switch purpose {
            case .updated:
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            case .available(_, let updater):
                if let reason = updater.cannotInstallReason {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if case .failed(let message) = updater.phase {
                    Text(message).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Later", action: done)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                switch updater.phase {
                case .downloading:
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                    Text("Downloading…").foregroundStyle(.secondary)
                case .installing:
                    Text("Restarting…").foregroundStyle(.secondary)
                default:
                    Button(updater.canInstall ? "Update and Restart" : "Download") {
                        updater.installAvailable()
                        if !updater.canInstall { done() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
            }
        }
    }
}

/// One release: version, date, how big it is, and each pull request with its kind.
private struct ReleaseCard: View {
    let release: GitHubRelease

    var body: some View {
        let changes = UpdatePlanner.changes(release.body ?? "")
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(release.version?.description ?? release.tag)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                if let biggest = changes.map(\.kind).max() {
                    Text(biggest.releaseLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(biggest.tint)
                }
                Spacer()
                if let date = release.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            if changes.isEmpty {
                Text("Behind-the-scenes changes only.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    KindPill(kind: change.kind)
                    Text(change.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AboutMascot.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

private struct KindPill: View {
    let kind: ChangeKind

    var body: some View {
        Text(kind.label.uppercased())
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(kind.tint)
            .frame(width: 66)
            .padding(.vertical, 3)
            .background(kind.tint.opacity(0.18), in: Capsule())
            .accessibilityLabel(kind.label)
    }
}

extension ChangeKind {
    var tint: Color {
        switch self {
        case .breaking: AboutMascot.red
        case .feature: AboutMascot.orange
        case .fix: AboutMascot.sky
        case .other: Color.gray
        }
    }
}
