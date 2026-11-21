import CadenceCore
import SwiftUI

struct SettingsScreen: View {
    @Environment(PhoneState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var showPairing = false
    @State private var authError: String?
    @State private var newFeedURL = ""
    @State private var deviceName = ""

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
                    Section {
                        ForEach(state.calendars.filter { state.isCalendarEnabled($0.id) }) { cal in
                            Toggle(isOn: Binding(get: { state.isCalendarAgendaOnly(cal.id) },
                                                 set: { state.setCalendar(cal.id, agendaOnly: $0) })) {
                                Label { Text(cal.title); Text(cal.sourceTitle) } icon: {
                                    Circle().fill(Color(cal.color)).frame(width: 10, height: 10)
                                }
                            }
                        }
                    } header: {
                        Text("Agenda only")
                    } footer: {
                        Text("Shown in the agenda, but never alert, notify or count as your next meeting. Handy for long room bookings. Calendars from the Mac follow its settings.")
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
                    Button("Preview meltdown") { dismiss(); state.previewLateAlert() }
                } header: { Text("Alerts") } footer: {
                    Text("Once a meeting has started the alert gets redder and more insistent for the first 3 minutes, then starts falling apart (not with Reduce Motion). While connected, the Mac decides when alerts fire and when they close, using its own settings.")
                }
                Section {
                    NavigationLink {
                        WorkHoursScreen()
                    } label: {
                        LabeledContent("Working hours & breaks",
                                       value: state.schedule.enabled ? (state.scheduleFromMac != nil ? "From Mac" : "On") : "Off")
                    }
                } footer: {
                    Text("Gives the desk display its moments: before work, focus time, breaks and the end of the day.")
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
                    Toggle("Meeting notes button", isOn: $state.prefs.deskEnrichments)
                    Toggle("Open notes when a meeting starts", isOn: $state.prefs.deskEnrichmentsAutoOpen)
                        .disabled(!state.prefs.deskEnrichments)
                } header: { Text("Desk mode") } footer: {
                    Text("Put your iPhone on a MagSafe stand or charger and Cadence becomes a desk clock for your meetings. While it's showing and connected, your Mac stays quiet.")
                }
                Section {
                    Toggle("Media controls", isOn: $state.prefs.deskMediaControls)
                    Picker("Media app", selection: $state.prefs.mediaApp) {
                        ForEach(MediaApp.allCases) { app in
                            Label { Text(app.name) } icon: { MediaLogo(app: app, size: 22) }.tag(app)
                        }
                    }
                    if state.prefs.mediaApp == .spotify {
                        NavigationLink {
                            SpotifySetupScreen()
                        } label: {
                            LabeledContent("Spotify app", value: state.spotify.customClientID != nil ? "Your own"
                                           : state.spotify.isAvailable ? "Built-in" : "Not set up")
                        }
                    }
                    if state.prefs.mediaApp == .spotify && state.spotify.isAvailable {
                        if state.spotify.connected {
                            LabeledContent("Spotify", value: "Connected")
                        } else {
                            Button(state.spotify.needsAuthorization ? "Connect Spotify" : "Reconnect Spotify") { state.spotify.authorize() }
                        }
                        if let error = state.spotify.lastError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        if !state.spotify.needsAuthorization {
                            Button("Disconnect Spotify", role: .destructive) { state.spotify.signOut() }
                        }
                    }
                    Toggle("Fade out for meetings", isOn: $state.prefs.pauseMediaForAlerts)
                    Toggle("Announce the meeting", isOn: $state.prefs.announceAlerts)
                        .disabled(!state.prefs.pauseMediaForAlerts)
                    Button("Test the hand-off") { state.testAudioHandoff() }
                } header: { Text("Media") } footer: {
                    Text("Landscape desk mode shows what's playing in the corner, or a button for your media app. Track details and skip work for Apple Music and, once set up and connected, Spotify (with your own free Spotify developer app; connecting opens Spotify for a moment to approve); other apps show that they're playing and can be paused. When connected, it shows and controls the Mac's Music or Spotify too (and, if you turn it on in Cadence on the Mac, the Mac's media keys control this iPhone's music).\n\nWhen an alert comes up with music playing here, Cadence fades it out, says which meeting it is, then lets go of the audio so your headphones can switch to the Mac. Siri's own voice isn't available to apps: for a better voice, download an Enhanced or Premium one in Settings → Accessibility → Spoken Content → Voices.")
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
                Section {
                    Toggle("Show tomorrow's first meeting", isOn: $state.prefs.widgetShowsTomorrow)
                    Picker("From", selection: $state.prefs.widgetTomorrowHour) {
                        ForEach(Array(12...23), id: \.self) { hour in
                            Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
                                .formatted(date: .omitted, time: .shortened)).tag(hour)
                        }
                    }
                    .disabled(!state.prefs.widgetShowsTomorrow)
                } header: { Text("Widgets") } footer: {
                    Text("Once today's meetings are over, the Home Screen and Lock Screen widgets show when your first meeting tomorrow is, from this time on.")
                }
                Section("Filters") {
                    Toggle("Hide all-day events", isOn: $state.prefs.filters.hideAllDay)
                    Toggle("Hide declined", isOn: $state.prefs.filters.hideDeclined)
                    Toggle("Hide tentative", isOn: $state.prefs.filters.hideTentative)
                    Toggle("Hide free", isOn: $state.prefs.filters.hideFree)
                    Toggle("Only events with a join link", isOn: $state.prefs.filters.onlyWithJoinLink)
                }
                Section {
                    NavigationLink {
                        ScrollView { AboutView() }
                            .background(Color(.systemBackground))
                            .navigationTitle("About")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("About Cadence")
                                Text(AboutView.version).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "face.smiling")
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(LinearGradient(colors: [AboutMascot.pink, AboutMascot.orange],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showPairing) { PairingScreen() }
            .alert("Sign-in failed", isPresented: Binding(get: { authError != nil }, set: { if !$0 { authError = nil } })) {
                Button("OK") {}
            } message: { Text(authError ?? "") }

        }
    }

    @ViewBuilder private var macSection: some View {
        @Bindable var state = state
        Section {
            if !state.link.links.isEmpty {
                ForEach(state.link.links) { mac in
                    NavigationLink {
                        MacDetailScreen(link: mac)
                    } label: {
                        LabeledContent {
                            Text(Self.statusText(mac.status)).font(.caption).foregroundStyle(.secondary)
                        } label: {
                            Label(mac.mac.displayName, systemImage: "laptopcomputer")
                        }
                    }
                }
                .onMove { state.link.move(fromOffsets: $0, toOffset: $1) }
                Button("Pair another Mac") { showPairing = true }
                if state.link.links.count > 1 {
                    Toggle(isOn: $state.prefs.joinOnPriorityMac) {
                        Text("Open web links on \(state.link.macs.first?.displayName ?? "the first Mac")")
                        Text("A meeting only one Mac has still opens there, unless its link works in any browser: then it opens on the first Mac.")
                    }
                }
                LabeledContent("This iPhone") {
                    TextField(state.link.defaultDeviceName, text: $deviceName)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .onSubmit { state.link.renameDevice(deviceName) }
                }
                .onAppear { deviceName = state.link.deviceName }
                .onChange(of: deviceName) { state.link.renameDevice(deviceName) }
            } else {
                Button("Pair with Cadence on your Mac") { showPairing = true }
            }
        } header: {
            HStack {
                Text(state.link.links.count > 1 ? "Macs" : "Mac")
                if state.link.links.count > 1 {
                    Spacer()
                    EditButton().font(.caption).textCase(nil)
                }
            }
        } footer: {
            Text(state.link.links.isEmpty
                 ? "Paired and on the same Wi-Fi (or nearby), the phone shows the Mac's meetings and Join opens the meeting on the Mac."
                 : state.link.links.count > 1
                 ? "Drag to set priority (Edit): a meeting more than one connected Mac has opens on the highest. This iPhone: what the Macs call this phone. The phone keeps a copy of each Mac's agenda so it carries on without them."
                 : "This iPhone: what the Mac calls this phone; blank uses the device's own name. Pair another Mac to have meetings from both. The phone remembers the Mac's address on each network it pairs or connects on, for a week after it last worked, and keeps a copy of the Mac's agenda so it carries on without the Mac.")
        }
    }

    static func statusText(_ status: CompanionClient.Status) -> String {
        switch status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .searching: "Looking…"
        case .failed: "Unavailable"
        case .off: "Not connected"
        case .unpaired: "Pair again"
        }
    }

    @ViewBuilder private var accountsSection: some View {
        Section {
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
        } header: { Text("Calendars on this iPhone") } footer: {
            if state.link.mac != nil {
                Text("Optional while paired: the phone gets everything from the Mac and keeps today's and tomorrow's agenda when it can't reach it.")
            }
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

/// One paired Mac: its name on this phone, how it's connected, and unpairing it.
private struct MacDetailScreen: View {
    @Environment(PhoneState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let link: MacLink
    @State private var nickname = ""
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(status).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                LabeledContent("Name") {
                    TextField(link.mac.name, text: $nickname)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .onSubmit { state.link.rename(link.mac.id, nickname) }
                }
                .onAppear { nickname = link.mac.nickname ?? "" }
                .onChange(of: nickname) { state.link.rename(link.mac.id, nickname) }
            } footer: {
                Text("Name: shown on Join buttons and in the Dynamic Island, e.g. \"Join on Work laptop\". Leave blank for the Mac's own name.")
            }
            if link.needsRescan {
                Section {
                    Text("Can't reach this Mac. Make sure Cadence is open on it and you're on the same Wi-Fi, or scan its pairing code again (Pair another Mac).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Unpair", role: .destructive) { confirmUnpair = true }
            }
        }
        .confirmationDialog("Unpair from \(link.mac.displayName)?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) {
                state.unpair(link.mac.id)
                dismiss()
            }
        } message: {
            Text("Its meetings leave this iPhone. Scan its pairing code to pair it again.")
        }
        .navigationTitle(link.mac.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var status: String {
        if case .failed(let why) = link.status { return why }
        return SettingsScreen.statusText(link.status)
    }
}

/// Working hours, breaks and how they're defended. Paired to a Mac that sends its schedule, shows that
/// one read-only (set it in Cadence on the Mac, Settings → Work).
private struct WorkHoursScreen: View {
    @Environment(PhoneState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            if let mac = state.scheduleFromMac {
                Section {
                    Text("Set on \(state.link.mac?.displayName ?? "your Mac") in Settings → Work. Unpair to use your own here.")
                        .foregroundStyle(.secondary)
                }
                WorkScheduleEditor(schedule: .constant(mac), readOnly: true)
            } else {
                WorkScheduleEditor(schedule: $state.prefs.workSchedule,
                                   defencesFooter: "Without a Mac, this iPhone nudges you when breaks start. Invite flags and break questions come from Cadence on the Mac.")
            }
        }
        .navigationTitle("Working Hours")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Bring-your-own Spotify developer app. Spotify's App Remote SDK needs a client ID, and an app
/// in development mode only works for accounts its owner adds, so each person makes their own.
private struct SpotifySetupScreen: View {
    @Environment(PhoneState.self) private var state
    @State private var clientID = ""
    @State private var copied: String?

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "" }
    private var redirectURI: String { SpotifyRemote.redirectURL.absoluteString }
    private var trimmed: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmed != (state.spotify.customClientID ?? "") }

    var body: some View {
        Form {
            Section {
                TextField("32-character Client ID", text: $clientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                    .submitLabel(.done)
                    .onSubmit(save)
                if !trimmed.isEmpty && !SpotifyRemote.isValidClientID(trimmed) {
                    Text("That doesn't look like a Client ID: it's 32 letters and numbers, from your app's Settings page.")
                        .font(.footnote).foregroundStyle(.red)
                }
                Button("Save") { save() }
                    .disabled(!changed || (!trimmed.isEmpty && !SpotifyRemote.isValidClientID(trimmed)))
                if state.spotify.customClientID != nil {
                    Button(state.spotify.hasBundledClientID ? "Use the built-in app" : "Remove", role: .destructive) {
                        clientID = ""
                        state.spotify.setClientID(nil)
                    }
                }
            } header: { Text("Client ID") } footer: {
                Text("Saving a different one disconnects Spotify; connect again afterwards. The Client ID isn't a secret (there's no Client Secret to enter), and it stays on this iPhone.")
            }
            Section {
                Link("Open the Spotify Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                Text("1. Sign in with your Spotify account and tap **Create app**. Any name and description will do.")
                Text("2. Under **Redirect URIs**, add:")
                copyRow(redirectURI)
                Text("3. Under **Which API/SDKs are you planning to use?** tick **iOS**, then add this **Bundle ID**:")
                copyRow(bundleID)
                Text("4. Save, open the app's **Settings** and copy its **Client ID** into the field above.")
            } header: { Text("Make your own Spotify app") } footer: {
                Text("It's free and takes a couple of minutes. Spotify keeps new apps in development mode, which is fine here: they work for the account that made them (add anyone else under User Management).")
            }
        }
        .navigationTitle("Spotify app")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { clientID = state.spotify.customClientID ?? "" }
    }

    private func save() {
        guard changed, trimmed.isEmpty || SpotifyRemote.isValidClientID(trimmed) else { return }
        state.spotify.setClientID(trimmed)
    }

    private func copyRow(_ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = value
        } label: {
            HStack {
                Text(value).font(.callout.monospaced()).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.6)
                Spacer()
                Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
            }
        }
    }
}
