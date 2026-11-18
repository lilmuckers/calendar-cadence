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

extension PanelStyle {
    var size: NSSize {
        switch self {
        case .standard: NSSize(width: 300, height: 92)
        case .compact: NSSize(width: 244, height: 46)
        case .mini: NSSize(width: 118, height: 30)
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .standard: 20
        case .compact: 14
        case .mini: 15
        }
    }
}

@MainActor
final class CountdownPanelController: NSObject, NSWindowDelegate {
    private static let originKey = "Cadence.panel.origin"
    private let panel: FloatingPanel
    private let state: AppState
    private var snapWork: DispatchWorkItem?
    private var shownStyle: PanelStyle

    init(state: AppState) {
        self.state = state
        shownStyle = state.panelStyle
        panel = FloatingPanel(size: shownStyle.size)
        super.init()
        let host = NSHostingView(rootView: CountdownPanelView().environment(state))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: shownStyle.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.delegate = self
        restorePosition()
    }

    /// Show, hide or resize based on preferences and what's coming up.
    func update() {
        let focus = state.panelFocus
        // With an "only within N minutes" window, an empty panel is pointless, so hide it.
        let idleVisible = !state.prefs.panelHidesWhenIdle && state.prefs.panelWithinMinutes == 0
        let visible = state.prefs.showPanel && (focus != nil && state.canShowAgenda || idleVisible)
            && CompanionRouting.macShowsPanel(phoneDisplaying: state.companion.phoneDisplaying)
        resize(to: state.panelStyle, animated: panel.isVisible)
        if visible && !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        } else if !visible && panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// Change size while keeping the corner nearest the screen corner fixed, so a panel
    /// parked top-right grows down and left.
    private func resize(to style: PanelStyle, animated: Bool) {
        guard style != shownStyle else { return }
        shownStyle = style
        let size = style.size
        var f = panel.frame
        let v = (panel.screen ?? NSScreen.main)?.visibleFrame ?? f
        let anchorRight = f.midX > v.midX
        let anchorTop = f.midY > v.midY
        let newX = anchorRight ? f.maxX - size.width : f.minX
        let newY = anchorTop ? f.maxY - size.height : f.minY
        f = NSRect(x: newX, y: newY, width: size.width, height: size.height)
        panel.delegate = nil
        let restore: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.panel.delegate = self
                    UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: Self.originKey)
                }
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(f, display: true)
            }, completionHandler: restore)
        } else {
            panel.setFrame(f, display: true)
            restore()
        }
    }

    private func restorePosition() {
        let size = shownStyle.size
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let origin = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(NSRect(origin: origin, size: size)) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16))
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

/// The glass pill: what's next and how long until it starts. Drawn in one of three sizes.
struct CountdownPanelView: View {
    @Environment(AppState.self) private var state
    @State private var hovering = false

    var body: some View {
        let style = state.panelStyle
        let focus = state.panelFocus
        ZStack {
            VisualEffect(material: .hudWindow)
            Group {
                if let focus {
                    switch style {
                    case .standard: standard(focus)
                    case .compact: compact(focus)
                    case .mini: mini(focus)
                    }
                } else {
                    idle(style)
                }
            }
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovering && style == .standard {
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
        .animation(.easeInOut(duration: 0.25), value: style)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(focus.map { "\($0.meeting.title) · \(Theme.time($0.meeting.start))" } ?? "")
        .contextMenu { menu(focus) }
    }

    @ViewBuilder private func menu(_ focus: PanelFocus?) -> some View {
        @Bindable var state = state
        if let m = focus?.meeting {
            if m.joinLink != nil {
                Button("Join \(m.title)") { state.join(m) }
                JoinInMenu(meeting: m)
            }
            RunningLateMenu(meeting: m)
            ClashAlertsMenu(meeting: m)
            PanelVisibilityMenu(meeting: m)
            Divider()
        }
        Picker("Style", selection: $state.prefs.panelStyle) {
            ForEach(PanelStyle.allCases.reversed(), id: \.self) { Text($0.label).tag($0) }
        }
        Toggle("Grow as Meetings Approach", isOn: $state.prefs.panelGrow)
        Divider()
        Button("Hide Panel") { state.prefs.showPanel = false }
    }

    // MARK: Styles

    private func remaining(_ f: PanelFocus) -> TimeInterval { f.target.timeIntervalSince(state.now) }
    private func urgent(_ f: PanelFocus) -> Bool { !f.live && remaining(f) <= 300 }

    private func symbol(_ f: PanelFocus) -> String {
        f.live ? "waveform" : (f.meeting.joinLink?.service.symbol ?? (f.meeting.physicalLocation != nil ? "mappin" : "calendar"))
    }

    private func countdown(_ f: PanelFocus, size: CGFloat, compactHours: Bool = false) -> some View {
        let r = remaining(f)
        let text = compactHours && r >= 3600 ? CountdownFormatter.short(r) : CountdownFormatter.clock(r)
        return Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(urgent(f) ? f.meeting.tint : .primary)
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: Int(r))
            .lineLimit(1)
    }

    private func ringIcon(_ f: PanelFocus, diameter: CGFloat, line: CGFloat, icon: CGFloat) -> some View {
        let m = f.meeting
        return ZStack {
            Circle().stroke(m.tint.opacity(0.18), lineWidth: line)
            Circle()
                .trim(from: 0, to: ring(f))
                .stroke(m.tint.gradient, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: state.now)
            Image(systemName: symbol(f))
                .font(.system(size: icon, weight: .semibold))
                .foregroundStyle(m.tint)
                .symbolEffect(.pulse, isActive: urgent(f) || f.live)
        }
        .frame(width: diameter, height: diameter)
    }

    private func wash(_ f: PanelFocus) -> some View {
        LinearGradient(colors: [f.meeting.tint.opacity(urgent(f) ? 0.28 : 0.14), .clear], startPoint: .leading, endPoint: .trailing)
    }

    private func standard(_ f: PanelFocus) -> some View {
        let m = f.meeting
        return HStack(spacing: 12) {
            ringIcon(f, diameter: 44, line: 4, icon: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.live ? "NOW · ENDS IN" : "UP NEXT · \(Theme.time(m.start))")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(m.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                countdown(f, size: 20)
            }
            Spacer(minLength: 0)
            JoinButton(meeting: m, size: .small)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { wash(f) }
    }

    private func compact(_ f: PanelFocus) -> some View {
        let m = f.meeting
        return HStack(spacing: 9) {
            ringIcon(f, diameter: 26, line: 2.5, icon: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(m.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(f.live ? "ends in" : "at \(Theme.time(m.start))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            countdown(f, size: 15, compactHours: true)
            JoinIconButton(meeting: m, diameter: 24)
        }
        .padding(.leading, 10)
        .padding(.trailing, m.joinLink == nil ? 12 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { wash(f) }
    }

    private func mini(_ f: PanelFocus) -> some View {
        let m = f.meeting
        return HStack(spacing: 6) {
            Image(systemName: symbol(f))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(m.tint)
                .symbolEffect(.pulse, isActive: urgent(f) || f.live)
                .frame(width: 14)
            countdown(f, size: 13, compactHours: true)
            Spacer(minLength: 0)
            JoinIconButton(meeting: m, diameter: 20)
        }
        .padding(.leading, 10)
        .padding(.trailing, m.joinLink == nil ? 10 : 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Thin progress line along the bottom stands in for the ring.
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    wash(f)
                    Rectangle().fill(m.tint.gradient)
                        .frame(width: geo.size.width * ring(f), height: 2)
                        .animation(.linear(duration: 1), value: state.now)
                }
            }
        }
    }

    @ViewBuilder private func idle(_ style: PanelStyle) -> some View {
        switch style {
        case .mini:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.system(size: 11))
                Text("All clear").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        case .compact, .standard:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: style == .standard ? 22 : 16, weight: .light))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All clear").font(.system(size: style == .standard ? 13 : 12, weight: .semibold))
                    Text(state.next.map { "Next: \($0.start.formatted(.relative(presentation: .named)))" } ?? "No more meetings today")
                        .font(.system(size: style == .standard ? 11 : 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, style == .standard ? 16 : 12)
        }
    }

    /// Fills as the meeting approaches (last hour) or as a live meeting progresses.
    private func ring(_ f: PanelFocus) -> CGFloat {
        let m = f.meeting
        if f.live {
            guard m.duration > 0 else { return 1 }
            return CGFloat(min(1, max(0, state.now.timeIntervalSince(m.start) / m.duration)))
        }
        let window: TimeInterval = 3600
        return CGFloat(min(1, max(0.02, 1 - m.start.timeIntervalSince(state.now) / window)))
    }
}

/// Round, icon-only Join for the small panel styles.
struct JoinIconButton: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    let diameter: CGFloat

    var body: some View {
        if let link = meeting.joinLink {
            Button { state.join(meeting) } label: {
                Image(systemName: link.service.symbol)
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: diameter, height: diameter)
                    .background(Circle().fill(meeting.tint.gradient))
                    .shadow(color: meeting.tint.opacity(0.35), radius: 3, y: 1)
            }
            .buttonStyle(PressableStyle())
            .help(state.joinHint(for: meeting) ?? "Join on \(link.service.displayName)")
        }
    }
}
