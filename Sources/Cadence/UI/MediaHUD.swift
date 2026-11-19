import AppKit
import CadenceCore
import Observation
import SwiftUI

/// What the Mac's mini-player for the phone shows.
@MainActor
@Observable
final class MediaHUDModel {
    enum Part: Equatable { case volume, playPause, next, previous }

    var media: CompanionMedia?
    var artwork: NSImage?
    var volume: Double?
    var muted = false
    var phoneName = "iPhone"
    /// The part the last key press changed, lit up for a moment.
    var highlight: Part?
    /// The phone's player last time it said, for the look while nothing's playing.
    var lastApp: MediaApp = .spotify
    var app: MediaApp { media?.app ?? lastApp }
}

/// A small floating mini-player in the bottom-right corner of the main screen: what the phone's
/// playing, its volume, and previous / play-pause / next. Never takes focus.
@MainActor
final class MediaHUDController {
    private static let size = NSSize(width: 340, height: 104)
    let model = MediaHUDModel()
    var send: (MediaCommand) -> Void = { _ in }

    private var panel: FloatingPanel?
    private var hideTimer: Timer?
    private var highlightTimer: Timer?
    private(set) var pinned = false

    var isVisible: Bool { panel?.isVisible == true && panel?.alphaValue ?? 0 > 0 }

    /// After a key press: show (for a couple of seconds unless pinned) and light up what changed.
    func flash(_ part: MediaHUDModel.Part?) {
        model.highlight = part
        highlightTimer?.invalidate()
        highlightTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { withAnimation(.easeOut(duration: 0.3)) { self?.model.highlight = nil } }
        }
        show()
        if !pinned { scheduleHide(after: 2.2) }
    }

    /// Always-on mode: stays up until `unpin`.
    func pin() {
        guard !pinned else { return }
        pinned = true
        hideTimer?.invalidate()
        show()
    }

    func unpin(hide: Bool) {
        pinned = false
        if hide { self.hide() }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.pinned == false { self?.hide() } }
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let frame = NSRect(x: v.maxX - Self.size.width - 16, y: v.minY + 16, width: Self.size.width, height: Self.size.height)
        if !isVisible {
            panel.setFrame(frame.offsetBy(dx: 0, dy: -12), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        } else if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    func hide() {
        hideTimer?.invalidate()
        pinned = false
        guard let panel, isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(size: Self.size)
        panel.level = .statusBar
        panel.isMovableByWindowBackground = false
        let host = NSHostingView(rootView: MediaHUDView(model: model, send: { [weak self] in self?.tapped($0) }))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func tapped(_ command: MediaCommand) {
        send(command)
        flash(command == .togglePlayPause ? .playPause : command == .next ? .next : .previous)
    }
}

private struct MediaHUDView: View {
    let model: MediaHUDModel
    let send: (MediaCommand) -> Void

    var body: some View {
        let app = model.app
        let theme = app.theme
        let media = model.media
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(media?.title ?? (media == nil ? "Nothing playing" : "Playing on \(model.phoneName)"))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "iphone").font(.system(size: 10))
                        Text([media?.title == nil ? app.name : media?.artist, "on \(model.phoneName)"]
                            .compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
                    }
                    .font(.system(size: 11)).foregroundStyle(theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 2) {
                    if media?.canSkip == true { control("backward.fill", .previous, part: .previous) }
                    control(media?.isPlaying == true ? "pause.fill" : "play.fill", .togglePlayPause, part: .playPause, big: true)
                    if media?.canSkip == true { control("forward.fill", .next, part: .next) }
                }
            }
            volumeRow(theme)
        }
        .foregroundStyle(theme.foreground)
        .padding(12)
        .frame(width: 340, height: 104)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
        .overlay(alignment: .topTrailing) { MediaLogo(app: app, size: 16).offset(x: -6, y: 6) }
        .animation(.easeOut(duration: 0.15), value: model.volume)
        .animation(.easeOut(duration: 0.2), value: model.highlight)
    }

    @ViewBuilder private var artwork: some View {
        if let image = model.artwork {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            MediaLogo(app: model.app, size: 44)
        }
    }

    private func volumeRow(_ theme: MediaTheme) -> some View {
        let lit = model.highlight == .volume
        let level = model.muted ? 0 : (model.volume ?? 0)
        let symbol = model.muted || level == 0 ? "speaker.slash.fill"
            : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        return HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 18)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.foreground.opacity(0.18))
                    Capsule().fill(lit ? theme.accent : theme.foreground.opacity(0.85))
                        .frame(width: max(0, geo.size.width * level))
                }
            }
            .frame(height: lit ? 7 : 5)
            Text(model.volume == nil ? "–" : "\(Int((level * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(lit ? theme.foreground : theme.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .scaleEffect(lit ? 1.02 : 1, anchor: .leading)
    }

    private func control(_ symbol: String, _ command: MediaCommand, part: MediaHUDModel.Part, big: Bool = false) -> some View {
        let theme = model.app.theme
        let lit = model.highlight == part
        return Button { send(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: big ? 15 : 12, weight: .bold))
                .frame(width: big ? 34 : 28, height: 34)
                .background(big && theme.accentFill ? theme.accent : (lit ? theme.accent.opacity(0.3) : .clear), in: Circle())
                .foregroundStyle(big && theme.accentFill ? theme.onAccent : theme.foreground)
                .overlay(Circle().strokeBorder(theme.accent, lineWidth: lit ? 2 : 0).padding(-3))
                .scaleEffect(lit ? 1.12 : 1)
        }
        .buttonStyle(.plain)
    }
}
