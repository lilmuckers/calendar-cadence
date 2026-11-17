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
    private var takeover: TakeoverController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = CountdownPanelController(state: state)
        let takeover = TakeoverController(state: state)
        self.panel = panel
        self.takeover = takeover

        state.onAlert = { meeting in takeover.present(meeting) }
        state.onPrefsChanged = { panel.update() }
        state.start()

        // Re-evaluate panel visibility whenever the observed state it depends on changes.
        observePanel()
    }

    private func observePanel() {
        withObservationTracking {
            _ = state.access
            _ = state.prefs.showPanel
            _ = state.prefs.panelHidesWhenIdle
            _ = state.isNextToday
            _ = state.current.isEmpty
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
