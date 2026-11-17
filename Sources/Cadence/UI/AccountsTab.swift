import CadenceCore
import SwiftUI

/// Settings → Accounts: subscribed ICS feeds and a direct Google Calendar connection.
struct AccountsTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Provider status isn't observable itself; every provider change triggers a refresh, so read this to redraw.
        let _ = state.lastRefresh
        Form {
            Section {
                LabeledContent("macOS Calendar") {
                    Text(state.access == .granted ? "Connected" : "No access")
                        .foregroundStyle(state.access == .granted ? Color.secondary : Color.orange)
                }
            } footer: {
                Text("Includes every account in System Settings → Internet Accounts (iCloud, Google, Exchange, CalDAV).")
                    .foregroundStyle(.secondary)
            }
            GoogleSection()
            FeedsSection()
        }
        .formStyle(.grouped)
    }
}

private struct GoogleSection: View {
    @Environment(AppState.self) private var state
    @State private var clientID = UserDefaults.standard.string(forKey: "Cadence.google.clientID") ?? ""
    @State private var clientSecret = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section {
            if state.googleAuth.isSignedIn {
                LabeledContent("Account", value: state.google.accountEmail ?? "Signed in")
                LabeledContent("Status") { Text(state.google.status).foregroundStyle(.secondary) }
                Button("Sign Out", role: .destructive) { state.googleSignOut() }
            } else {
                TextField("Client ID", text: $clientID, prompt: Text("xxxx.apps.googleusercontent.com"))
                SecureField("Client secret", text: $clientSecret, prompt: Text(state.googleAuth.credentials == nil ? "Required" : "Saved — leave blank to keep"))
                HStack {
                    Button(busy ? "Waiting for browser…" : "Sign in with Google") { signIn() }
                        .disabled(busy || clientID.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (clientSecret.isEmpty && state.googleAuth.credentials == nil))
                    if busy { ProgressView().controlSize(.small) }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        } header: {
            Text("Google Calendar (direct)")
        } footer: {
            Text("""
            Optional — gives Meet links and RSVP status straight from Google. Needs your own OAuth client: \
            Google Cloud Console → enable the Google Calendar API → Credentials → Create OAuth client ID → \
            Application type "Desktop app". Add yourself as a test user on the consent screen. \
            Events that also arrive via macOS Calendar are merged, not duplicated.
            """)
            .foregroundStyle(.secondary)
        }
    }

    private func signIn() {
        let secret = clientSecret.isEmpty ? (state.googleAuth.credentials?.clientSecret ?? "") : clientSecret
        state.googleAuth.saveCredentials(clientID: clientID, clientSecret: secret)
        busy = true
        error = nil
        Task {
            do {
                try await state.googleSignIn()
                clientSecret = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct FeedsSection: View {
    @Environment(AppState.self) private var state
    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        @Bindable var state = state
        Section {
            ForEach($state.prefs.icsFeeds) { $feed in
                HStack(spacing: 10) {
                    Circle().fill(Color(feed.color)).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.name)
                        Text(status(for: feed))
                            .font(.caption)
                            .foregroundStyle(status(for: feed).hasPrefix("Error") ? Color.red : Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: $feed.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Button {
                        state.prefs.icsFeeds.removeAll { $0.id == feed.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove feed")
                }
            }
            HStack {
                TextField("Name", text: $newName, prompt: Text("Team rota"))
                    .frame(width: 120)
                TextField("URL", text: $newURL, prompt: Text("https://… or webcal://…ics"))
                Button("Add", action: add)
                    .disabled(!isValid)
            }
        } header: {
            Text("Subscribed calendars (ICS)")
        } footer: {
            Text("Any iCalendar link works: Google \"Secret address in iCal format\", Outlook \"Publish calendar\" ICS, iCloud public calendars, sports and holiday feeds. Refreshed every 10 minutes.")
                .foregroundStyle(.secondary)
        }
    }

    private var isValid: Bool {
        let u = newURL.trimmingCharacters(in: .whitespaces).lowercased()
        return u.hasPrefix("https://") || u.hasPrefix("http://") || u.hasPrefix("webcal://")
    }

    private func add() {
        let color = ICSFeed.palette[state.prefs.icsFeeds.count % ICSFeed.palette.count]
        let name = newName.trimmingCharacters(in: .whitespaces)
        let url = newURL.trimmingCharacters(in: .whitespaces)
        state.prefs.icsFeeds.append(ICSFeed(name: name.isEmpty ? (URL(string: url)?.host ?? "Feed") : name, url: url, color: color))
        newName = ""
        newURL = ""
    }

    private func status(for feed: ICSFeed) -> String {
        guard feed.enabled else { return "Paused" }
        return state.icsProviders.first { $0.feed.id == feed.id }?.status ?? "Waiting…"
    }
}
