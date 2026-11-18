import SwiftUI

@main
struct CadenceCompanionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = PhoneState.shared

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
    }
}
