import AppKit
import SwiftUI

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environment(delegate.state)
        } label: {
            MenuBarLabel(state: delegate.state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(delegate.state)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var panel: CountdownPanelController?
    private var router: AlertRouter?
    private var clashPrompt: ClashPromptController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--screenshots") {
            let dir = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "screenshots"
            ScreenshotRenderer.run(state: state, to: URL(fileURLWithPath: dir))
            NSApp.terminate(nil)
            return
        }
        let panel = CountdownPanelController(state: state)
        let router = AlertRouter(state: state)
        self.panel = panel
        self.router = router

        let clashPrompt = ClashPromptController(state: state)
        self.clashPrompt = clashPrompt

        state.onAlert = { meeting, style in router.alert(meeting, forcing: style) }
        state.onReminder = { reminder in router.remind(reminder) }
        state.onClash = { clash in clashPrompt.enqueue(clash) }

        let hotKey = GlobalHotKey.shared
        hotKey.action = { [weak self] in self?.state.joinFromHotKey() }
        hotKey.register(state.prefs.joinHotKey)
        var registered = state.prefs.joinHotKey
        state.onPrefsChanged = { [weak self] in
            panel.update()
            guard let self, self.state.prefs.joinHotKey != registered else { return }
            registered = self.state.prefs.joinHotKey
            hotKey.register(registered)
        }
        state.start()

        // Re-evaluate panel visibility whenever the observed state it depends on changes.
        observePanel()
    }

    private func observePanel() {
        withObservationTracking {
            _ = state.canShowAgenda
            _ = state.prefs.showPanel
            _ = state.prefs.panelHidesWhenIdle
            _ = state.prefs.panelWithinMinutes
            _ = state.panelFocus == nil
            _ = state.panelStyle
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.panel?.update()
                    self?.observePanel()
                }
            }
        }
        panel?.update()
    }
}
