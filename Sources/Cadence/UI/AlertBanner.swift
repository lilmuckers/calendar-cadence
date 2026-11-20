import AppKit
import CadenceCore
import SwiftUI

/// Small top-of-screen banner used while presenting or on a call. Never takes keyboard focus,
/// so keystrokes keep going to Keynote, Zoom, etc.
@MainActor
final class BannerController {
    private static let size = NSSize(width: 460, height: 64)
    private let state: AppState
    private var panels: [FloatingPanel] = []
    private var autoClose: Timer?

    init(state: AppState) {
        self.state = state
    }

    func present(_ meeting: Meeting, on screens: [NSScreen]) {
        dismiss(animated: false)
        for screen in screens {
            let panel = FloatingPanel(size: Self.size)
            panel.level = .statusBar
            panel.isMovableByWindowBackground = false
            let view = BannerView(meeting: meeting, dismiss: { [weak self] in self?.dismiss() })
                .environment(state)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: Self.size)
            panel.contentView = host

            let v = screen.visibleFrame
            let final = NSRect(x: v.midX - Self.size.width / 2, y: v.maxY - Self.size.height - 10,
                               width: Self.size.width, height: Self.size.height)
            panel.setFrame(final.offsetBy(dx: 0, dy: 24), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(final, display: true)
                panel.animator().alphaValue = 1
            }
            panels.append(panel)
        }
        if state.prefs.takeoverSound { NSSound(named: "Tink")?.play() }

        autoClose?.invalidate()
        let closeAt = max(meeting.start.addingTimeInterval(120), Date().addingTimeInterval(20))
        autoClose = Timer.scheduledTimer(withTimeInterval: closeAt.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss(animated: Bool = true) {
        autoClose?.invalidate()
        autoClose = nil
        let closing = panels
        panels = []
        guard animated else { closing.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            closing.forEach { $0.orderOut(nil) }
        })
    }
}

struct BannerView: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    let dismiss: () -> Void

    private var remaining: TimeInterval { meeting.start.timeIntervalSince(state.clock.now) }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: MenuBarIcon.image(.panicking))
                .renderingMode(.template)
                .foregroundStyle(meeting.tint)
                .scaleEffect(1.3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(remaining > 0 ? "Starts in \(CountdownFormatter.clock(remaining))" : "Started \(CountdownFormatter.short(-remaining)) ago")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: Int(remaining))
            }
            Spacer(minLength: 8)
            JoinButton(meeting: meeting, size: .small, afterJoin: dismiss)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(width: 460, height: 64)
        .background(VisualEffect(material: .hudWindow))
        .background(alignment: .leading) {
            LinearGradient(colors: [meeting.tint.opacity(0.22), .clear], startPoint: .leading, endPoint: .center)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}
