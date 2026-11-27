import SwiftUI
import TipKit

@main
struct CadenceCompanionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = PhoneState.shared

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetTips") { try? Tips.resetDatastore() }
        #endif
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .onAppear { state.start() }
                .onOpenURL { state.open($0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    state.setActive(phase == .active)
                }
                .onChange(of: state.prefs.deskWhenCharging, initial: true) { _, on in
                    state.desk.autoWhenCharging = on
                }
        }
        // A missed meeting's time is up: take its Live Activity down.
        .backgroundTask(.appRefresh(PhoneState.missedCheckTask)) {
            await PhoneState.shared.backgroundRefresh()
        }
        // Fetch the calendars so the widgets pick up meetings added since the app was last open.
        .backgroundTask(.appRefresh(PhoneState.calendarRefreshTask)) {
            await PhoneState.shared.backgroundRefresh()
        }
    }
}
