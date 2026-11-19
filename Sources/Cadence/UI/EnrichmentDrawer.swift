import AppKit
import CadenceCore
import Observation
import SwiftUI

/// The panel behind the drawer: never activates Cadence, but takes keystrokes while open (log entries).
final class DrawerPanel: NSPanel {
    var acceptsKey = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 34),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class DrawerModel {
    var expanded = false
    var meetingID: String?
}

/// A small "Notes" button at the bottom of the screen during a meeting with enrichments; click it and
/// it slides up into a drawer with the notes, links, checklists, bingo card…
@MainActor
final class EnrichmentDrawerController {
    static let handleSize = NSSize(width: 170, height: 34)
    private let panel = DrawerPanel()
    private let state: AppState
    private let model = DrawerModel()
    /// Opened by hand (menu, countdown panel) for a meeting that isn't the automatic one.
    private var pinnedMeetingID: String?
    private var autoOpened: Set<String> = []

    init(state: AppState) {
        self.state = state
        let view = EnrichmentDrawerView(model: model,
                                        toggle: { [weak self] in self?.setExpanded(!(self?.model.expanded ?? false)) },
                                        close: { [weak self] in self?.dismiss() })
            .environment(state)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    /// Opens the drawer for a meeting (from the menu bar or countdown panel).
    func show(_ meeting: Meeting) {
        pinnedMeetingID = meeting.id
        update()
        setExpanded(true)
    }

    func update() {
        let auto = state.prefs.showEnrichmentDrawer ? state.enrichmentFocus() : nil
        var meeting = auto
        if let pinned = pinnedMeetingID {
            if let m = state.meeting(id: pinned), m.end > state.now, !state.enrichments(for: m).isEmpty { meeting = m } else { pinnedMeetingID = nil }
        }
        guard let meeting else {
            if panel.isVisible { hide() }
            model.meetingID = nil
            return
        }
        let changed = model.meetingID != meeting.id
        model.meetingID = meeting.id
        if changed && model.expanded { setExpanded(false, animated: false) }
        if !panel.isVisible {
            panel.setFrame(frame(expanded: model.expanded), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        }
        if state.prefs.enrichmentDrawerAutoOpen, meeting.isInProgress(at: state.now), !autoOpened.contains(meeting.id) {
            autoOpened.insert(meeting.id)
            setExpanded(true)
        }
    }

    private func hide() {
        panel.acceptsKey = false
        model.expanded = false
        panel.orderOut(nil)
    }

    /// The close button: collapse, and forget a hand-opened meeting.
    private func dismiss() {
        pinnedMeetingID = nil
        setExpanded(false)
        update()
    }

    private func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard model.meetingID != nil else { return }
        panel.acceptsKey = expanded
        let target = frame(expanded: expanded)
        if expanded {
            // Grow the window first, then let the content spring in.
            panel.setFrame(target, display: true, animate: false)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { model.expanded = true }
            panel.makeKey()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { model.expanded = false }
            panel.resignKey()
            let shrink = { [weak self] in
                guard let self, !self.model.expanded else { return }
                self.panel.setFrame(self.frame(expanded: false), display: true)
            }
            if animated { DispatchQueue.main.asyncAfter(deadline: .now() + 0.33, execute: shrink) } else { shrink() }
        }
    }

    /// Bottom-centre of the screen with the mouse (else the main one).
    private func frame(expanded: Bool) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = expanded
            ? NSSize(width: min(560, v.width - 40), height: min(640, v.height * 0.7))
            : Self.handleSize
        return NSRect(x: v.midX - size.width / 2, y: v.minY + 8, width: size.width, height: size.height)
    }
}

/// Handle when collapsed; the whole drawer when open. The window is sized to the drawer while it
/// animates, so the content slides up from the handle's spot at the bottom.
struct EnrichmentDrawerView: View {
    @Environment(AppState.self) private var state
    let model: DrawerModel
    let toggle: () -> Void
    let close: () -> Void

    var body: some View {
        let meeting = model.meetingID.flatMap(state.meeting(id:))
        ZStack(alignment: .bottom) {
            if let meeting {
                if model.expanded {
                    drawer(meeting)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    handle(meeting)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
    }

    private func handle(_ m: Meeting) -> some View {
        let count = state.enrichments(for: m).count
        return Button(action: toggle) {
            HStack(spacing: 7) {
                Circle().fill(m.tint).frame(width: 8, height: 8)
                Text(count == 1 ? state.enrichments(for: m)[0].title : "Notes · \(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: EnrichmentDrawerController.handleSize.height)
            .background(VisualEffect().clipShape(Capsule()))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show what's attached to \(m.title)")
    }

    private func drawer(_ m: Meeting) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let live = m.isInProgress(at: state.now)
        return VStack(alignment: .leading, spacing: 12) {
            Button(action: toggle) {
                Capsule().fill(.white.opacity(0.3)).frame(width: 40, height: 5).frame(maxWidth: .infinity).padding(.top, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(live ? "ENDS IN \(CountdownFormatter.clock(m.end.timeIntervalSince(state.now)))"
                              : "STARTS IN \(CountdownFormatter.clock(m.start.timeIntervalSince(state.now)))")
                        .font(.system(size: 10, weight: .heavy).monospacedDigit()).kerning(1.2)
                        .foregroundStyle(m.tint)
                    Text(m.title).font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1)
                }
                Spacer()
                if m.joinLink != nil && !live { JoinButton(meeting: m) }
                Button(action: close) {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
            EnrichmentPanel(meeting: m, enrichments: state.enrichments(for: m), state: { state.enrichmentState($0, m) },
                            now: state.now) { action in
                state.applyEnrichment(action, meetingID: m.id)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(VisualEffect().clipShape(shape))
        .background(shape.fill(LinearGradient(colors: [m.tint.opacity(0.25), .clear], startPoint: .top, endPoint: .center)))
        .overlay(shape.strokeBorder(.white.opacity(0.12)))
        .clipShape(shape)
        .onExitCommand(perform: toggle)
    }
}
