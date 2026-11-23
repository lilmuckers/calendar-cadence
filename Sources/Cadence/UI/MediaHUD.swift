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
    /// Showing the small pill (compact mode, not hovered).
    var collapsed = false
    var app: MediaApp { media?.app ?? lastApp }
}

/// A small floating mini-player, bottom-right of the main screen until dragged somewhere else
/// (where it then stays): what the phone's playing, its volume, and previous / play-pause / next.
/// In compact mode it's a small pill (artwork, track, playing or paused) that opens into the full
/// player while the pointer is over it. Never takes focus.
@MainActor
final class MediaHUDController {
    private static let size = NSSize(width: 340, height: 104)
    static let compactSize = NSSize(width: 240, height: 52)
    let model = MediaHUDModel()
    var send: (MediaCommand) -> Void = { _ in }
    /// Small until hovered (Settings → iPhone → Music).
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            hovering = false
            if isVisible { place(animated: true) }
        }
    }

    private var panel: FloatingPanel?
    private var hideTimer: Timer?
    private var highlightTimer: Timer?
    private var collapseTimer: Timer?
    private var hovering = false
    private(set) var pinned = false
    private var moveObserver: NSObjectProtocol?
    /// Set while Cadence moves the panel itself, so only a drag is remembered.
    private var placing = false
    /// The bottom-right corner it was dragged to: both sizes grow out of that corner.
    private static let anchorKey = "Cadence.mediaHUD.anchor"

    private var showsCompact: Bool { compact && !hovering }
    private var currentSize: NSSize { showsCompact ? Self.compactSize : Self.size }

    /// Where it goes at `size`: the dragged-to corner if it's still on a screen, else bottom-right,
    /// always kept fully on screen.
    private func frame(for size: NSSize) -> NSRect? {
        var anchor: NSPoint?
        if let text = UserDefaults.standard.string(forKey: Self.anchorKey) { anchor = NSPointFromString(text) }
        let probe = anchor.map { NSRect(x: $0.x - size.width, y: $0.y, width: size.width, height: size.height) }
        let screen = probe.flatMap { p in
            NSScreen.screens.filter { $0.visibleFrame.intersects(p) }
                .max { $0.visibleFrame.intersection(p).area < $1.visibleFrame.intersection(p).area }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }
        let v = screen.visibleFrame
        let corner = (probe != nil && screen.visibleFrame.intersects(probe!)) ? anchor! : NSPoint(x: v.maxX - 16, y: v.minY + 16)
        let x = min(max(corner.x - size.width, v.minX), v.maxX - size.width)
        let y = min(max(corner.y, v.minY), v.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Moves/resizes the panel to match the mode and hover.
    private func place(animated: Bool) {
        guard let panel, let target = frame(for: currentSize) else { return }
        let collapsed = showsCompact
        placing = true
        withAnimation(.easeOut(duration: 0.18)) { model.collapsed = collapsed }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated ? 0.18 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.placing = false } })
    }

    fileprivate func hoverChanged(_ inside: Bool) {
        collapseTimer?.invalidate()
        if inside {
            hideTimer?.invalidate()
            guard compact, !hovering else { return }
            hovering = true
            place(animated: true)
        } else {
            if !pinned { scheduleHide(after: 2.2) }
            guard hovering else { return }
            // A beat before closing, so brushing past the edge doesn't make it jump.
            collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.hovering else { return }
                    self.hovering = false
                    self.place(animated: true)
                }
            }
        }
    }

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
        model.collapsed = showsCompact
        guard let frame = frame(for: currentSize) else { return }
        placing = true
        defer { placing = false }
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
        }
    }

    func hide() {
        hideTimer?.invalidate()
        collapseTimer?.invalidate()
        hovering = false
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
        panel.isMovableByWindowBackground = true
        let host = HoverHostingView(rootView: MediaHUDView(model: model, send: { [weak self] in self?.tapped($0) }))
        host.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, !self.placing, let window = note.object as? NSWindow else { return }
                let corner = NSPoint(x: window.frame.maxX, y: window.frame.minY)
                UserDefaults.standard.set(NSStringFromPoint(corner), forKey: Self.anchorKey)
            }
        }
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
        if model.collapsed { pill.transition(.opacity) } else { full.transition(.opacity) }
    }

    /// Compact: laid out like the phone's media card, showing only what's playing and whether
    /// it's playing. Hovering opens the full player.
    private var pill: some View {
        let app = model.app
        let theme = app.theme
        let media = model.media
        return HStack(spacing: 8) {
            Group {
                if let image = model.artwork {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    MediaLogo(app: app, size: 32)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(media?.title ?? (media == nil ? "Nothing playing" : app.name))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(media?.title == nil ? "on \(model.phoneName)" : media?.artist ?? "on \(model.phoneName)")
                    .font(.system(size: 10.5)).foregroundStyle(theme.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: media?.isPlaying == true ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .background(theme.accentFill ? theme.accent : theme.foreground.opacity(0.12), in: Circle())
                .foregroundStyle(theme.accentFill ? theme.onAccent : theme.foreground)
                .scaleEffect(model.highlight == .playPause ? 1.15 : 1)
        }
        .foregroundStyle(theme.foreground)
        .padding(.horizontal, 10)
        .frame(width: MediaHUDController.compactSize.width, height: MediaHUDController.compactSize.height)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: model.highlight)
    }

    private var full: some View {
        let app = model.app
        let theme = app.theme
        let media = model.media
        return VStack(alignment: .leading, spacing: 8) {
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

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// The mini-player's view, telling the controller when the pointer comes and goes (even while
/// Cadence isn't the active app, which SwiftUI's own hover doesn't).
private final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: (Bool) -> Void = { _ in }
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover(false)
    }
}
