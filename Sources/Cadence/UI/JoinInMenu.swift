import CadenceCore
import SwiftUI

/// "Join in ▸" — pick a browser profile for this join, and optionally remember it.
/// Only shown when the default browser has profiles Cadence can target.
struct JoinInMenu: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting

    var body: some View {
        let store = state.browsers
        if store.supportsProfiles, meeting.joinLink != nil {
            let choice = state.profileChoice(for: meeting)
            Menu("Join in") {
                if let choice {
                    Text("Usually \(choice.profile.title) · \(choice.reason)")
                    Divider()
                }
                ForEach(store.profiles) { p in
                    Button {
                        state.join(meeting, in: p, remember: nil)
                    } label: {
                        if choice?.profile == p { Label(label(p), systemImage: "checkmark") } else { Text(label(p)) }
                    }
                }
                Button("\(store.defaultBrowserName) (no profile)") { state.join(meeting, in: nil, remember: nil) }
                Divider()
                Menu("Always Use for This Meeting") {
                    ForEach(store.profiles) { p in
                        Button(label(p)) { state.join(meeting, in: p, remember: .once) }
                    }
                }
                if state.isRecurring(meeting) {
                    Menu("Always Use for This Series") {
                        ForEach(store.profiles) { p in
                            Button(label(p)) { state.join(meeting, in: p, remember: .series) }
                        }
                    }
                }
                if choice?.source == .meeting || choice?.source == .series {
                    Button("Forget Choice for This Meeting") { state.forgetProfileChoice(meeting) }
                }
            }
        }
    }

    private func label(_ p: BrowserProfile) -> String {
        if let email = p.email, p.container == nil { return "\(p.title) — \(email)" }
        return p.title
    }
}
