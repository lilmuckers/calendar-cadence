import AppKit
import Observation
import SwiftUI

/// A bouncing arrow under Cadence's menu-bar icon, so first-time users can see where it lives.
/// Shown during setup's welcome step. Finds the icon through the status bar window that holds it;
/// when there's none on screen (hidden behind the notch, or the menu bar is hidden) it shows nothing.
@MainActor
@Observable
final class MenuBarPointer {
    static let shared = MenuBarPointer()

    /// False while the icon can't be seen: a full-screen app or auto-hide has put the menu bar away
    /// (it slides back when the pointer reaches the top of the screen), or it's behind the notch.
    private(set) var iconVisible = true

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var timer: Timer?
    private static let size = NSSize(width: 230, height: 92)

    func show() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PointerView())
        self.panel = panel
        place()
        // The icon moves as the countdown beside it changes width, and other apps' icons come and go.
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarPointer.shared.place() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        iconVisible = true
    }

    private func place() {
        guard let panel else { return }
        guard let icon = Self.iconFrame(), let screen = NSScreen.screens.first(where: { $0.frame.intersects(icon) }) else {
            panel.orderOut(nil)
            if iconVisible { iconVisible = false }
            return
        }
        if !iconVisible { iconVisible = true }
        var x = icon.midX - Self.size.width / 2
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - Self.size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: icon.minY - Self.size.height - 2))
        // Where the arrow sits across the panel, so it points at the icon even when clamped to the edge.
        (panel.contentView as? NSHostingView<PointerView>)?.rootView = PointerView(arrowX: icon.midX - x)
        panel.orderFrontRegardless()
    }

    /// The screen frame of Cadence's status item, if it's showing.
    private static func iconFrame() -> NSRect? {
        NSApp.windows
            .first { $0.className.contains("NSStatusBarWindow") && $0.isVisible && $0.occlusionState.contains(.visible) }
            .map(\.frame)
            .flatMap { $0.width > 0 ? $0 : nil }
    }
}

private struct PointerView: View {
    var arrowX: CGFloat = 115
    @State private var up = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.up")
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(AboutMascot.orange)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .offset(y: up ? -6 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, max(0, arrowX - 13))
            Text("Cadence lives up here")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(LinearGradient(colors: [AboutMascot.pink, AboutMascot.orange],
                                                          startPoint: .leading, endPoint: .trailing)))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
        .frame(width: 230, height: 92, alignment: .top)
        .padding(.top, 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { up = true }
        }
    }
}
