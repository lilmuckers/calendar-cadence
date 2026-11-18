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
    var currentID: String? { current?.id }
    /// Called with the meeting id whenever the takeover closes, unless the phone closed it.
    var onClosed: ((String) -> Void)?

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

        // If ignored, close the chosen number of minutes after the start (or when the meeting ends,
        // if sooner). "Never" leaves it up until the user acts.
        autoClose?.invalidate()
        autoClose = nil
        let minutes = state.prefs.takeoverAutoDismissMinutes
        guard minutes > 0 else { return }
        let giveUp = min(meeting.start.addingTimeInterval(TimeInterval(minutes * 60)), meeting.end)
        let closeAt = max(giveUp, Date().addingTimeInterval(30))
        autoClose = Timer.scheduledTimer(withTimeInterval: closeAt.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss(notify: Bool = true) {
        if notify, let id = current?.id { onClosed?(id) }
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
    @State private var clock = PulseClock()
    @State private var meltdown = MeltdownModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var remaining: TimeInterval { meeting.start.timeIntervalSince(state.now) }
    /// How late you are, counted from when you said you'd be there once you've sent a running-late message.
    private var secondsLate: TimeInterval { state.now.timeIntervalSince(state.lateClockStart(for: meeting)) }
    /// Grows from calm to full panic over the first few minutes the user is late.
    private var urgency: TakeoverUrgency { TakeoverUrgency(secondsLate: secondsLate) }

    private var headline: String {
        guard let notice = state.lateNotices[meeting.id] else { return TakeoverUrgency.headline(remaining: remaining) }
        if state.now < notice.promised { return "THEY KNOW YOU'RE ON YOUR WAY" }
        // You said you'd be there by now: straight back to "late".
        return TakeoverUrgency.headline(remaining: -max(30, secondsLate))
    }
    /// The meeting's colour, turning red as panic sets in.
    private var mood: Color { Color(urgency.color(from: meeting.displayColor)) }

    var body: some View {
        TimelineView(.animation) { context in
            let u = urgency
            let phase = clock.advance(to: context.date, period: reduceMotion ? 2 : u.period)
            let pulse = (1 - cos(phase * 2 * .pi)) / 2
            content(urgency: u, phase: phase, pulse: reduceMotion ? 0.5 : pulse, date: context.date)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true } }
    }

    private var clockText: String {
        remaining > 0 ? CountdownFormatter.clock(remaining) : "-" + CountdownFormatter.clock(-remaining)
    }

    @ViewBuilder private func content(urgency u: TakeoverUrgency, phase: Double, pulse: Double, date: Date) -> some View {
        let shake = reduceMotion ? 0 : u.shake
        // Three minutes late and still ignored: things start falling off.
        let melting = !reduceMotion && Meltdown.isActive(secondsLate: secondsLate)
        let headline = self.headline
        ZStack {
            VisualEffect(material: .fullScreenUI)
            Color.black.opacity(0.45)
            // A red wash that throbs with the pulse once the user is properly late.
            Color.red.opacity(0.22 * u.alarm * pulse)
            // The glow is a circle of its own, sized to the screen's diagonal and drawn in an overlay, so it never
            // gets cut by the screen's edges: scaling the screen-sized rectangle used to shrink those hard
            // top and bottom cut-offs into view as it pulsed.
            GeometryReader { geo in
                let radius = hypot(geo.size.width, geo.size.height) / 2
                Color.clear.overlay {
                    Circle()
                        .fill(RadialGradient(colors: [mood.opacity(0.55 + 0.2 * u.level), .clear], center: .center,
                                             startRadius: 20, endRadius: radius * 0.75))
                        .frame(width: radius * 2, height: radius * 2)
                        .scaleEffect(u.scaleRange.lowerBound + (u.scaleRange.upperBound - u.scaleRange.lowerBound) * pulse)
                        .opacity(remaining <= 10 && remaining > 0 ? 1 : u.glowOpacity)
                }
            }
            .allowsHitTesting(false)
            // Red edges flash in time with the pulse at full panic.
            Rectangle()
                .strokeBorder(Color.red, lineWidth: 70)
                .blur(radius: 45)
                .opacity(u.alarm * pulse)
                .allowsHitTesting(false)

            VStack(spacing: 28) {
                if melting {
                    BreakableText(text: headline, idPrefix: "h", style: .heading, broken: meltdown.brokenLetters,
                                  tracking: 4, wordSpacing: 14)
                        .font(GlyphStyle.heading.font(level: u.level))
                        .foregroundStyle(mood)
                } else {
                    Text(headline)
                        .font(GlyphStyle.heading.font(level: u.level))
                        .tracking(4)
                        .foregroundStyle(u.level > 0 ? AnyShapeStyle(mood) : AnyShapeStyle(.white.opacity(0.6)))
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: headline)
                }

                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(mood.gradient, style: StrokeStyle(lineWidth: 6 + 4 * u.level, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: state.now)
                    if melting {
                        BreakableCountdown(text: clockText, broken: meltdown.brokenSlots)
                            .font(GlyphStyle.countdown.font(level: u.level))
                            .foregroundStyle(.white)
                        // Broken-off characters keep counting while they rattle around the ring.
                        ForEach(meltdown.bottle, id: \.slot) { piece in
                            if let ch = BreakableCountdown.character(in: clockText, slot: piece.slot) {
                                Text(String(ch))
                                    .font(GlyphStyle.countdown.font(level: u.level))
                                    .foregroundStyle(.white)
                                    .rotationEffect(.radians(piece.angle))
                                    .offset(x: piece.position.x, y: piece.position.y)
                            }
                        }
                    } else {
                        Text(clockText)
                            .font(GlyphStyle.countdown.font(level: u.level))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy, value: Int(remaining))
                    }
                }
                .frame(width: 260, height: 260)
                .transformAnchorPreference(key: GlyphAnchorKey.self, value: .bounds) { $0["ring"] = $1 }

                VStack(spacing: 10) {
                    if melting {
                        BreakableText(text: meeting.title, idPrefix: "t", style: .title, broken: meltdown.brokenLetters,
                                      wordSpacing: 11)
                            .font(GlyphStyle.title.font(level: u.level))
                            .foregroundStyle(.white)
                    } else {
                        Text(meeting.title)
                            .font(GlyphStyle.title.font(level: u.level))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
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

                if isPrimary, remaining <= 0, state.prefs.lateMessages.enabled {
                    RunningLateCard(meeting: meeting, afterSend: actions.dismiss)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if isPrimary {
                    Text(meeting.joinLink != nil ? "Return to join  ·  Esc to dismiss" : "Esc to dismiss")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(40)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
            .offset(x: shake * sin(phase * 2 * .pi * 2.3), y: shake * 0.4 * cos(phase * 2 * .pi * 3.1))
        }
        .overlayPreferenceValue(GlyphAnchorKey.self) { anchors in
            if melting {
                GeometryReader { geo in
                    let _ = tickMeltdown(anchors: anchors, geo: geo, date: date, headline: headline)
                    ForEach(meltdown.falling, id: \.id) { piece in
                        if let glyph = meltdown.fallingGlyph[piece.id] {
                            Text(String(glyph.0))
                                .font(glyph.1.font(level: u.level))
                                .foregroundStyle(glyph.1 == .heading ? mood : .white)
                                .rotationEffect(.radians(piece.angle))
                                .position(x: piece.position.x, y: piece.position.y)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Feeds the meltdown where every breakable character is right now, then advances it a frame.
    private func tickMeltdown(anchors: [String: Anchor<CGRect>], geo: GeometryProxy, date: Date, headline: String) -> Bool {
        let heading = Array(headline), title = Array(meeting.title), clock = clockText
        var glyphs: [String: (CGRect, Character, GlyphStyle)] = [:]
        for (id, anchor) in anchors where id != "ring" {
            let parts = id.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[1]) else { continue }
            switch parts[0] {
            case "h" where n < heading.count: glyphs[id] = (geo[anchor], heading[n], .heading)
            case "t" where n < title.count: glyphs[id] = (geo[anchor], title[n], .title)
            case "d": if let ch = BreakableCountdown.character(in: clock, slot: n) { glyphs[id] = (geo[anchor], ch, .countdown) }
            default: break
            }
        }
        let ring = anchors["ring"].map { geo[$0] }
        meltdown.tick(date: date, secondsLate: secondsLate, glyphs: glyphs,
                      ringCenter: ring.map { CGPoint(x: $0.midX, y: $0.midY) }, screen: geo.size) { piece in
            guard state.prefs.takeoverSound else { return }
            NSSound(named: piece == .letter ? "Pop" : "Tink")?.play()
        }
        return true
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

/// Keeps the pulse's phase continuous while its speed changes, so speeding up never makes the glow jump.
private final class PulseClock {
    private var phase = 0.0
    private var last: Date?

    func advance(to date: Date, period: Double) -> Double {
        if let last { phase += min(0.1, max(0, date.timeIntervalSince(last))) / max(period, 0.05) }
        last = date
        if phase > 10_000 { phase = phase.truncatingRemainder(dividingBy: 1) }
        return phase
    }
}
