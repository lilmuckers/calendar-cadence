import AppKit
import CadenceCore
import SwiftUI

/// Borderless full-screen window above everything (including full-screen apps).
final class TakeoverWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Escape dismisses even when no button has focus.
    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .cadenceDismissTakeover, object: nil)
    }
}

extension Notification.Name {
    static let cadenceDismissTakeover = Notification.Name("CadenceDismissTakeover")
}

@MainActor
final class TakeoverController {
    private let state: AppState
    private var windows: [TakeoverWindow] = []
    private var autoClose: Timer?
    private var screenObserver: NSObjectProtocol?
    private var dismissObserver: NSObjectProtocol?
    private var current: Meeting?
    private var currentDisplays: [UInt32] = []

    init(state: AppState) {
        self.state = state
        dismissObserver = NotificationCenter.default.addObserver(forName: .cadenceDismissTakeover, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = self.current else { return }
                let remaining = self.currentDisplays.filter { SystemContext.screen(for: $0) != nil }
                if remaining.isEmpty { self.dismiss() } else { self.present(m, displays: remaining) }
            }
        }
    }

    var isPresented: Bool { !windows.isEmpty }

    /// Cover the given displays (by CGDirectDisplayID). The first one gets the keyboard hints.
    func present(_ meeting: Meeting, displays: [UInt32]) {
        closeWindows()
        current = meeting
        currentDisplays = displays
        let screens = displays.compactMap(SystemContext.screen(for:))
        for (index, screen) in screens.enumerated() {
            let window = TakeoverWindow(screen: screen)
            let view = TakeoverView(meeting: meeting, isPrimary: index == 0, actions: .init(
                snooze: { [weak self] in self?.state.snooze(meeting); self?.dismiss() },
                dismiss: { [weak self] in self?.dismiss() }
            ))
            .environment(state)
            window.contentView = NSHostingView(rootView: view)
            window.alphaValue = 0
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            windows.forEach { $0.animator().alphaValue = 1 }
        }
        if state.prefs.takeoverSound { NSSound(named: "Glass")?.play() }

        // Get out of the way two minutes after start if ignored.
        autoClose?.invalidate()
        let closeAt = max(meeting.start.addingTimeInterval(120), Date().addingTimeInterval(30))
        autoClose = Timer.scheduledTimer(withTimeInterval: closeAt.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        autoClose?.invalidate()
        autoClose = nil
        current = nil
        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            closing.forEach { $0.orderOut(nil) }
        })
    }

    private func closeWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

struct TakeoverActions {
    let snooze: () -> Void
    let dismiss: () -> Void
}

struct TakeoverView: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    let isPrimary: Bool
    let actions: TakeoverActions
    @State private var appeared = false

    private var remaining: TimeInterval { meeting.start.timeIntervalSince(state.now) }

    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI)
            Color.black.opacity(0.45)
            RadialGradient(colors: [meeting.tint.opacity(0.55), .clear], center: .center, startRadius: 20, endRadius: 700)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(remaining <= 10 && remaining > 0 ? 1 : 0.8)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: appeared)

            VStack(spacing: 28) {
                Text(remaining > 0 ? "STARTING IN" : "STARTED")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.6))

                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(meeting.tint.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: state.now)
                    Text(remaining > 0 ? CountdownFormatter.clock(remaining) : "-" + CountdownFormatter.clock(-remaining))
                        .font(.system(size: 88, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: Int(remaining))
                }
                .frame(width: 260, height: 260)

                VStack(spacing: 10) {
                    Text(meeting.title)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        Circle().fill(meeting.tint).frame(width: 8, height: 8)
                        Text(meeting.calendar.title)
                        Text("·")
                        Text(Theme.range(meeting))
                        if let loc = meeting.physicalLocation {
                            Text("·")
                            Label(loc, systemImage: "mappin").lineLimit(1)
                        }
                        if meeting.attendeeCount > 1 {
                            Text("·")
                            Label("\(meeting.attendeeCount)", systemImage: "person.2.fill")
                        }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: 900)

                HStack(spacing: 14) {
                    if meeting.joinLink != nil {
                        JoinButton(meeting: meeting, size: .large, afterJoin: actions.dismiss)
                            .keyboardShortcut(.defaultAction)
                    }
                    GhostButton(title: "Snooze 1 min", symbol: "zzz", action: actions.snooze)
                    GhostButton(title: "Dismiss", symbol: "xmark", action: actions.dismiss)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 8)

                if isPrimary {
                    Text(meeting.joinLink != nil ? "Return to join  ·  Esc to dismiss" : "Esc to dismiss")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(40)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true } }
    }

    private var ringProgress: CGFloat {
        let lead = max(state.prefs.takeoverLeadSeconds, 1)
        return CGFloat(min(1, max(0, 1 - remaining / lead)))
    }
}

private struct GhostButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .padding(.horizontal, 20)
                .padding(.vertical, 13)
                .foregroundStyle(.white.opacity(0.9))
                .background(Capsule().fill(.white.opacity(hovering ? 0.18 : 0.1)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}
