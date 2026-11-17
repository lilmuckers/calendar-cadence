import AppKit
import CadenceCore
import SwiftUI

/// Borderless, always-on-top panel that never steals focus.
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CountdownPanelController: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 300, height: 92)
    private static let originKey = "Cadence.panel.origin"
    private let panel = FloatingPanel(size: CountdownPanelController.size)
    private let state: AppState
    private var snapWork: DispatchWorkItem?

    init(state: AppState) {
        self.state = state
        super.init()
        let host = NSHostingView(rootView: CountdownPanelView().environment(state))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        panel.delegate = self
        restorePosition()
    }

    /// Show or hide based on preferences and whether anything is coming up.
    func update() {
        let hasContent = state.canShowAgenda && (state.isNextToday || !state.current.isEmpty)
        let visible = state.prefs.showPanel && (hasContent || !state.prefs.panelHidesWhenIdle)
        if visible && !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        } else if !visible && panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let origin = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(NSRect(origin: origin, size: Self.size)) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.maxX - Self.size.width - 16, y: v.maxY - Self.size.height - 16))
    }

    // Snap to the nearest screen edge shortly after the user stops dragging.
    func windowDidMove(_ notification: Notification) {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.snap() }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func snap() {
        guard NSEvent.pressedMouseButtons == 0 else {
            windowDidMove(Notification(name: NSWindow.didMoveNotification))
            return
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let margin: CGFloat = 16, threshold: CGFloat = 48
        var f = panel.frame
        if f.minX - v.minX < threshold { f.origin.x = v.minX + margin }
        if v.maxX - f.maxX < threshold { f.origin.x = v.maxX - f.width - margin }
        if f.minY - v.minY < threshold { f.origin.y = v.minY + margin }
        if v.maxY - f.maxY < threshold { f.origin.y = v.maxY - f.height - margin }
        // Keep fully on screen.
        f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        if f.origin != panel.frame.origin {
            panel.delegate = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                panel.animator().setFrame(f, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.panel.delegate = self
                }
            })
        }
        UserDefaults.standard.set(NSStringFromPoint(f.origin), forKey: Self.originKey)
    }
}

/// The glass pill: what's next and how long until it starts.
struct CountdownPanelView: View {
    @Environment(AppState.self) private var state
    @State private var hovering = false

    /// Show the upcoming meeting, unless one is live and the next is more than 10 minutes away.
    private var focus: (meeting: Meeting, live: Bool)? {
        let next = state.isNextToday ? state.next : nil
        if let cur = state.current.last {
            if let next, next.start.timeIntervalSince(state.now) <= 600 { return (next, false) }
            return (cur, true)
        }
        return next.map { ($0, false) }
    }

    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow)
            if let focus {
                content(focus.meeting, live: focus.live)
            } else {
                idle
            }
        }
        .frame(width: 300, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { state.prefs.showPanel = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(8)
                .help("Hide panel (re-enable from the menu bar)")
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private func content(_ m: Meeting, live: Bool) -> some View {
        let remaining = (live ? m.end : m.start).timeIntervalSince(state.now)
        let urgent = !live && remaining <= 300
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(m.tint.opacity(0.18), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: ring(m, live: live))
                    .stroke(m.tint.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: state.now)
                Image(systemName: live ? "waveform" : (m.joinLink?.service.symbol ?? (m.physicalLocation != nil ? "mappin" : "calendar")))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(m.tint)
                    .symbolEffect(.pulse, isActive: urgent || live)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(live ? "NOW · ENDS IN" : "UP NEXT · \(Theme.time(m.start))")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(m.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(CountdownFormatter.clock(remaining))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(urgent ? m.tint : .primary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: Int(remaining))
            }
            Spacer(minLength: 0)
            JoinButton(meeting: m, size: .small)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [m.tint.opacity(urgent ? 0.28 : 0.14), .clear], startPoint: .leading, endPoint: .trailing)
        }
    }

    private var idle: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("All clear").font(.system(size: 13, weight: .semibold))
                Text(state.next.map { "Next: \($0.start.formatted(.relative(presentation: .named)))" } ?? "No more meetings today")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    /// Ring fills as the meeting approaches (last hour) or as a live meeting progresses.
    private func ring(_ m: Meeting, live: Bool) -> CGFloat {
        if live {
            guard m.duration > 0 else { return 1 }
            return CGFloat(min(1, max(0, state.now.timeIntervalSince(m.start) / m.duration)))
        }
        let window: TimeInterval = 3600
        return CGFloat(min(1, max(0.02, 1 - m.start.timeIntervalSince(state.now) / window)))
    }
}
