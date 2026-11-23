import AppKit
import CadenceCore
import SwiftUI

/// The first-launch welcome (which asks how to handle updates) and the "What's new" screen shown
/// on the first launch after an update. Plain windows, since a menu-bar app has no SwiftUI
/// `openWindow` until its menu has been opened.
@MainActor
final class WelcomeWindows {
    private let state: AppState
    private var window: NSWindow?

    init(state: AppState) { self.state = state }

    func showWelcome() {
        present(title: "Welcome to Cadence", width: 480) { [state] close in
            WelcomeView(initial: state.prefs.updateMode ?? .notify) { mode in
                state.prefs.updateMode = mode
                close()
            }
            .environment(state)
        }
    }

    func showWhatsNew(from previous: SemVer?) {
        let updater = state.updater
        guard let current = updater.current else { return }
        Task {
            let releases = (try? await updater.fetchReleases()) ?? []
            let log = UpdatePlanner.changelog(releases, from: previous, to: current)
            present(title: "What's New in Cadence", width: 520) { close in
                WhatsNewView(version: current, releases: log, done: close)
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

/// The sunburst and the calendar character from About, still and small, as a header.
private struct MascotHeader: View {
    var mood: AboutMascot.Mood = .calm
    var height: CGFloat = 170

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height * 0.55)
                let t = timeline.date.timeIntervalSinceReferenceDate
                AboutMascot.drawSunburst(in: &ctx, size: size, center: center, time: t, mood: mood)
                AboutMascot.draw(in: &ctx, center: center, side: size.height * 0.72, time: t, mood: mood,
                                 pupils: [.zero, .zero], still: false)
            }
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

struct WelcomeView: View {
    let choose: (UpdateMode) -> Void
    @State private var mode: UpdateMode

    init(initial: UpdateMode, choose: @escaping (UpdateMode) -> Void) {
        self.choose = choose
        _mode = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            MascotHeader()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Cadence")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [AboutMascot.pink, AboutMascot.orange],
                                                        startPoint: .leading, endPoint: .trailing))
                    Text("Cadence lives in your menu bar and makes sure you're never late. First, one quick question:")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("How should Cadence stay up to date?")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                VStack(spacing: 8) {
                    ForEach([UpdateMode.automatic, .notify, .off]) { option in
                        UpdateModeCard(mode: option, selected: mode == option) { mode = option }
                    }
                }
                HStack {
                    Text("You can change this any time in Settings → General.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Get Started") { choose(mode) }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
            .padding(22)
        }
        .background(.background)
    }
}

private struct UpdateModeCard: View {
    let mode: UpdateMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background((selected ? AboutMascot.orange : Color.gray).gradient,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(mode.detail)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? AboutMascot.orange : .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AboutMascot.orange.opacity(0.12) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AboutMascot.orange.opacity(0.6) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WhatsNewView: View {
    let version: SemVer
    let releases: [GitHubRelease]
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MascotHeader(height: 130)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Updated to \(version.description)")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [AboutMascot.pink, AboutMascot.orange],
                                                        startPoint: .leading, endPoint: .trailing))
                    Text(releases.count > 1 ? "Here's what changed in the last \(releases.count) releases." : "Here's what changed.")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if MenuBarView.screenshotMode {
                    notes // ImageRenderer can't draw ScrollView contents.
                } else {
                    ScrollView { notes }.frame(height: 300)
                }
                HStack {
                    Link("All releases on GitHub", destination: AboutView.repo.appending(path: "releases"))
                        .font(.system(size: 12))
                    Spacer()
                    Button("Done", action: done)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
            .padding(22)
        }
        .background(.background)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 18) {
            if releases.isEmpty {
                Text("Couldn't load the release notes. They're on GitHub.")
                    .foregroundStyle(.secondary)
            }
            ForEach(releases) { release in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(release.version?.description ?? release.tag)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        if let date = release.publishedAt {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link("View", destination: release.page).font(.system(size: 11))
                    }
                    MarkdownView(text: UpdatePlanner.releaseNotes(release.body ?? ""), compact: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AboutMascot.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .environment(\.colorScheme, .dark)
            }
        }
    }
}
