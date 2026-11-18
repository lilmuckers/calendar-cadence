import CadenceCore
import SwiftUI

struct SettingsScreen: View {
    @Environment(PhoneState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var showPairing = false
    @State private var confirmUnpair = false
    @State private var authError: String?
    @State private var newFeedURL = ""

    var body: some View {
        @Bindable var state = state
        NavigationStack {
            Form {
                macSection
                accountsSection
                Section("Subscribed calendars (ICS)") {
                    ForEach(state.prefs.icsFeeds) { feed in
                        Text(feed.name).lineLimit(1)
                    }
                    .onDelete { state.prefs.icsFeeds.remove(atOffsets: $0) }
                    HStack {
                        TextField("webcal:// or https:// link", text: $newFeedURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button("Add") { addFeed() }.disabled(newFeedURL.isEmpty)
                    }
                }
                if !state.calendars.isEmpty {
                    Section("Show calendars") {
                        ForEach(state.calendars) { cal in
                            Toggle(isOn: Binding(get: { state.isCalendarEnabled(cal.id) },
                                                 set: { state.setCalendar(cal.id, enabled: $0) })) {
                                Label { Text(cal.title); Text(cal.sourceTitle) } icon: {
                                    Circle().fill(Color(cal.color)).frame(width: 10, height: 10)
                                }
                            }
                        }
                    }
                }
                Section {
                    Toggle("Full-screen alert", isOn: $state.prefs.takeoverEnabled)
                    Picker("Alert", selection: $state.prefs.takeoverLeadSeconds) {
                        ForEach([0.0, 15, 30, 60, 120, 300], id: \.self) { s in
                            Text(s == 0 ? "At start" : s < 60 ? "\(Int(s)) seconds before" : "\(Int(s) / 60) min before").tag(s)
                        }
                    }
                    Toggle("Only meetings with a join link", isOn: $state.prefs.takeoverOnlyWithLink)
                    Toggle("Sound", isOn: $state.prefs.alertSound)
                    Picker("If ignored, close after", selection: $state.prefs.takeoverAutoDismissMinutes) {
                        ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                        Text("Never").tag(0)
                    }
                    Button("Preview alert") { dismiss(); state.previewAlert() }
                } header: { Text("Alerts") } footer: {
                    Text("Once a meeting has started the alert gets redder and more insistent for the first 3 minutes. While connected, the Mac decides when alerts fire and when they close, using its own settings.")
                }
                Section("Notifications when Cadence isn't open") {
                    Toggle("Notify me", isOn: $state.prefs.backgroundNotifications)
                    Toggle("Heads-up", isOn: $state.prefs.headsUpEnabled)
                    Stepper("\(state.prefs.headsUpMinutes) min before", value: $state.prefs.headsUpMinutes, in: 1...30)
                        .disabled(!state.prefs.headsUpEnabled)
                    Toggle("Wrap-up before meetings end", isOn: $state.prefs.wrapUpEnabled)
                }
                Section {
                    Toggle("Turn on while charging", isOn: $state.prefs.deskWhenCharging)
                    Toggle("Dim when nothing's close", isOn: $state.prefs.deskDimWhenIdle)
                } header: { Text("Desk mode") } footer: {
                    Text("Put your iPhone on a MagSafe stand or charger and Cadence becomes a desk clock for your meetings. While it's showing and connected, your Mac stays quiet.")
                }
                Section {
                    Toggle("Live Activity", isOn: $state.prefs.liveActivityEnabled)
                    Picker("Count down from", selection: $state.prefs.liveActivityLeadMinutes) {
                        ForEach([10, 15, 30, 60, 120], id: \.self) { Text($0 >= 60 ? "\($0 / 60) h before" : "\($0) min before").tag($0) }
                    }
                    .disabled(!state.prefs.liveActivityEnabled)
                } header: { Text("Dynamic Island, Lock Screen & StandBy") } footer: {
                    Text("A countdown to your next meeting in the Dynamic Island and on the Lock Screen, with a Join button. Before then it shows when the meeting starts.")
                }
                Section("Filters") {
                    Toggle("Hide all-day events", isOn: $state.prefs.filters.hideAllDay)
                    Toggle("Hide declined", isOn: $state.prefs.filters.hideDeclined)
                    Toggle("Hide tentative", isOn: $state.prefs.filters.hideTentative)
                    Toggle("Hide free", isOn: $state.prefs.filters.hideFree)
                    Toggle("Only events with a join link", isOn: $state.prefs.filters.onlyWithJoinLink)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showPairing) { PairingScreen() }
            .alert("Sign-in failed", isPresented: Binding(get: { authError != nil }, set: { if !$0 { authError = nil } })) {
                Button("OK") {}
            } message: { Text(authError ?? "") }
            .confirmationDialog("Unpair from \(state.link.mac?.name ?? "Mac")?", isPresented: $confirmUnpair) {
                Button("Unpair", role: .destructive) { state.link.unpair() }
            }
        }
    }

    @ViewBuilder private var macSection: some View {
        Section {
            if let mac = state.link.mac {
                LabeledContent(mac.name) { ConnectionPill() }
                Button("Unpair", role: .destructive) { confirmUnpair = true }
            } else {
                Button("Pair with Cadence on your Mac") { showPairing = true }
            }
        } header: { Text("Mac") } footer: {
            Text("Paired and on the same Wi-Fi (or nearby), the phone shows the Mac's meetings and Join opens the meeting on the Mac.")
        }
    }

    @ViewBuilder private var accountsSection: some View {
        Section("Calendars on this iPhone") {
            if state.calendarAccess {
                Label("iPhone Calendar", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(state.calendarAccessDenied ? "Allow calendar access in Settings" : "Use iPhone Calendar accounts") {
                    if state.calendarAccessDenied {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } else {
                        Task { await state.requestCalendarAccess() }
                    }
                }
            }
            ForEach(state.googleAuth.accounts) { account in
                accountRow(account.label, kind: "Google", reconnect: state.googleAuth.needsReconnect.contains(account.id)) {
                    state.googleSignOut(account)
                }
            }
            ForEach(state.microsoftAuth.accounts) { account in
                accountRow(account.label, kind: "Microsoft 365", reconnect: state.microsoftAuth.needsReconnect.contains(account.id)) {
                    state.microsoftSignOut(account)
                }
            }
            Button("Sign in with Google") { signIn { try await state.googleSignIn() } }
                .disabled(state.googleAuth.credentials == nil)
            Button("Sign in with Microsoft") { signIn { try await state.microsoftSignIn() } }
                .disabled(state.microsoftAuth.clientID == nil)
        }
    }

    private func accountRow(_ label: String, kind: String, reconnect: Bool, signOut: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(label)
                Text(reconnect ? "\(kind) · needs reconnecting" : kind).font(.caption).foregroundStyle(reconnect ? .orange : .secondary)
            }
            Spacer()
            Button("Sign Out", role: .destructive, action: signOut).buttonStyle(.borderless)
        }
    }

    private func signIn(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { authError = error.localizedDescription }
        }
    }

    private func addFeed() {
        let raw = newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = URL(string: raw)?.host ?? "Calendar"
        state.prefs.icsFeeds.append(ICSFeed(name: name, url: raw, color: RGBAColor(red: 0.4, green: 0.6, blue: 0.95)))
        newFeedURL = ""
    }
}
