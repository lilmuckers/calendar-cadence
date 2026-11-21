import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Whether the window holding this view is on screen. The menu bar dropdown's window stays alive
    /// (ordered out) between openings, so looping animations check this to stop while it's hidden.
    @Entry var windowVisible = true
}

extension View {
    /// Publishes the hosting window's on-screen state as `\.windowVisible` to everything inside.
    func trackingWindowVisibility() -> some View { modifier(WindowVisibilityModifier()) }
}

private struct WindowVisibilityModifier: ViewModifier {
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .environment(\.windowVisible, visible)
            .background(WindowVisibilityReader(visible: $visible))
    }
}

private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { visible = $0 }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return report(false) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportWindow() }
            }
            reportWindow()
        }

        private func reportWindow() {
            report(window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
        }

        private func report(_ visible: Bool) {
            guard visible != last else { return }
            last = visible
            // Not during a view update.
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
