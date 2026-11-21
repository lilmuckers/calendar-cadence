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
                LabeledContent {
                    Text(state.access == .granted ? "Connected" : "No access")
                        .foregroundStyle(state.access == .granted ? Color.secondary : Color.orange)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar").font(.system(size: 16)).foregroundStyle(.red).frame(width: 22)
                        Text("macOS Calendar")
                    }
                }
                ForEach(macSources, id: \.title) { source in
                    HStack(spacing: 10) {
                        CalendarKindBadge(kind: source.kind, size: 18).frame(width: 22)
                        Text(source.title)
                        Spacer()
                        Text(source.count == 1 ? "1 calendar" : "\(source.count) calendars")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 14)
                }
            } footer: {
                Text("Includes every account in System Settings → Internet Accounts (iCloud, Google, Exchange, CalDAV).")
                    .foregroundStyle(.secondary)
            }
            GoogleSection()
            MicrosoftSection()
            SlackSection()
            FeedsSection()
        }
        .formStyle(.grouped)
    }

    /// Accounts that reach Cadence through macOS Calendar, with their type.
    private var macSources: [(title: String, kind: CalendarKind, count: Int)] {
        let direct: Set<CalendarKind> = [.google, .microsoft, .ics]
        return Dictionary(grouping: state.calendars.filter { !direct.contains($0.kind) }, by: \.sourceTitle)
            .map { (title: $0.key, kind: $0.value.first?.kind ?? .other, count: $0.value.count) }
            .sorted { $0.title < $1.title }
    }
}

/// Section header with a source badge.
private struct BadgedHeader: View {
    let kind: CalendarKind
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            CalendarKindBadge(kind: kind, size: 14)
            Text(title)
        }
    }
}

private struct GoogleSection: View {
    @Environment(AppState.self) private var state
    @State private var clientID = UserDefaults.standard.string(forKey: "Cadence.google.clientID") ?? ""
    @State private var clientSecret = ""
    @State private var busy = false
    @State private var error: String?
    /// Show the client ID/secret fields: always when no client is built in, otherwise on request.
    @State private var useOwnClient = false

    private var auth: GoogleAuth { state.googleAuth }
    private var needsClientFields: Bool { !auth.hasBundledClient || useOwnClient }

    var body: some View {
        Section {
            ForEach(auth.accounts) { account in
                AccountRow(account: account, busy: busy, reconnect: { signIn(custom: false) })
            }

            if needsClientFields {
                TextField("Client ID", text: $clientID, prompt: Text("xxxx.apps.googleusercontent.com"))
                SecureField("Client secret", text: $clientSecret,
                            prompt: Text(auth.customCredentials == nil ? "Required" : "Saved — leave blank to keep"))
            }
            HStack {
                Button {
                    signIn(custom: needsClientFields)
                } label: {
                    Label(busy ? "Waiting for browser…" : (auth.accounts.isEmpty ? "Sign in with Google" : "Add Another Account"),
                          systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(busy || (needsClientFields && !clientFieldsValid))
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if auth.hasBundledClient {
                    if useOwnClient {
                        Button("Use built-in client") {
                            state.googleUseBuiltInClient()
                            clientID = ""
                            clientSecret = ""
                            useOwnClient = false
                        }
                        .buttonStyle(.link)
                    } else {
                        Button("Use my own OAuth client…") { useOwnClient = true }
                            .buttonStyle(.link)
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            BadgedHeader(kind: .google, title: "Google Calendar (direct)")
        } footer: {
            Text(footer).foregroundStyle(.secondary)
        }
        .onAppear { useOwnClient = auth.customCredentials != nil }
    }

    private var clientFieldsValid: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty && (!clientSecret.isEmpty || auth.customCredentials != nil)
    }

    private var footer: String {
        var text = "Optional — Meet links and RSVP status straight from Google. Add as many accounts as you like; "
            + "Google shows its account chooser each time. Events that also arrive via macOS Calendar or another account are merged."
        if needsClientFields {
            text += " Needs a Google Cloud OAuth client of type \"Desktop app\" with the Google Calendar API enabled — see the README."
        }
        return text
    }

    private func signIn(custom: Bool) {
        if custom {
            let secret = clientSecret.isEmpty ? (auth.customCredentials?.clientSecret ?? "") : clientSecret
            auth.saveCredentials(clientID: clientID, clientSecret: secret)
        }
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

private struct AccountRow: View {
    @Environment(AppState.self) private var state
    let account: GoogleAccount
    let busy: Bool
    let reconnect: () -> Void
    @State private var confirmingSignOut = false

    private var provider: GoogleCalendarProvider? { state.googleProviders.first { $0.accountID == account.id } }
    private var needsReconnect: Bool { state.googleAuth.needsReconnect.contains(account.id) }

    var body: some View {
        // Provider status isn't observable; every fetch triggers a refresh, so read this to redraw.
        let _ = state.lastRefresh
        HStack(spacing: 10) {
            AccountAvatar(key: account.avatarKey, label: account.label, kind: .google)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                Text(provider?.status ?? "Connecting…")
                    .font(.caption)
                    .foregroundStyle(needsReconnect || (provider?.status.hasPrefix("Error") ?? false) ? Color.orange : Color.secondary)
                    .lineLimit(1)
                if account.canWrite == false && !needsReconnect {
                    Text("Read-only — reconnect to reply to invites and set colours")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                MessagingLine(
                    enabled: account.messagingEnabled == true,
                    channels: [account.canSendMail == true ? "Gmail" : nil, account.canChat == true ? "Google Chat" : nil].compactMap { $0 },
                    enable: { try await state.googleAuth.enableMessaging(account) },
                    disable: { state.googleAuth.disableMessaging(account) }
                )
            }
            Spacer()
            if needsReconnect || account.canWrite == false {
                Button("Reconnect", action: reconnect).disabled(busy)
                    .help("Sign in again and pick \(account.label)")
            }
            Button("Sign Out") { confirmingSignOut = true }
                .confirmationDialog("Sign out of \(account.label)?", isPresented: $confirmingSignOut) {
                    Button("Sign Out", role: .destructive) { state.googleSignOut(account) }
                } message: {
                    Text("Its calendars will disappear from Cadence. You can add it again any time.")
                }
        }
    }
}

private struct MicrosoftSection: View {
    @Environment(AppState.self) private var state
    @State private var clientID = UserDefaults.standard.string(forKey: "Cadence.microsoft.clientID") ?? ""
    @State private var busy = false
    @State private var error: String?
    @State private var useOwnClient = false
    @State private var confirmingSignOut: MicrosoftAccount?

    private var auth: MicrosoftAuth { state.microsoftAuth }
    private var needsClientField: Bool { !auth.hasBundledClient || useOwnClient }

    var body: some View {
        let _ = state.lastRefresh
        Section {
            ForEach(auth.accounts) { account in
                let provider = state.microsoftProviders.first { $0.accountID == account.id }
                let reconnect = auth.needsReconnect.contains(account.id) || account.canWrite == false
                HStack(spacing: 10) {
                    AccountAvatar(key: account.avatarKey, label: account.label, kind: .microsoft)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label)
                        Text(provider?.status ?? "Connecting…")
                            .font(.caption)
                            .foregroundStyle(reconnect || (provider?.status.hasPrefix("Error") ?? false) ? Color.orange : Color.secondary)
                            .lineLimit(1)
                        MessagingLine(
                            enabled: account.messagingEnabled == true,
                            channels: [account.canSendMail == true ? "Outlook mail" : nil, account.canTeamsChat == true ? "Teams chat" : nil].compactMap { $0 },
                            enable: { try await auth.enableMessaging(account) },
                            disable: { auth.disableMessaging(account) }
                        )
                    }
                    Spacer()
                    if reconnect { Button("Reconnect") { signIn() }.disabled(busy) }
                    Button("Sign Out") { confirmingSignOut = account }
                }
            }
            if needsClientField {
                TextField("Application (client) ID", text: $clientID, prompt: Text("00000000-0000-0000-0000-000000000000"))
            }
            HStack {
                Button(action: signIn) {
                    Label(busy ? "Waiting for browser…" : (auth.accounts.isEmpty ? "Sign in with Microsoft" : "Add Another Account"),
                          systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(busy || (needsClientField && clientID.trimmingCharacters(in: .whitespaces).isEmpty))
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if auth.hasBundledClient {
                    if useOwnClient {
                        Button("Use built-in app") {
                            state.microsoftUseBuiltInClient()
                            clientID = ""
                            useOwnClient = false
                        }
                        .buttonStyle(.link)
                    } else {
                        Button("Use my own app registration…") { useOwnClient = true }.buttonStyle(.link)
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            BadgedHeader(kind: .microsoft, title: "Microsoft 365 / Outlook (direct)")
        } footer: {
            Text("Optional — Teams links, RSVP status and replies straight from Outlook, for work, school or personal Microsoft accounts."
                 + (needsClientField ? " Needs an Azure app registration (public client, redirect http://localhost) — see the README." : ""))
                .foregroundStyle(.secondary)
        }
        .onAppear { useOwnClient = auth.customClientID != nil }
        .confirmationDialog("Sign out of \(confirmingSignOut?.label ?? "")?", isPresented: Binding(
            get: { confirmingSignOut != nil }, set: { if !$0 { confirmingSignOut = nil } })
        ) {
            Button("Sign Out", role: .destructive) {
                if let account = confirmingSignOut { state.microsoftSignOut(account) }
            }
        } message: {
            Text("Its calendars will disappear from Cadence. You can add it again any time.")
        }
    }

    private func signIn() {
        if needsClientField { auth.saveClientID(clientID) }
        busy = true
        error = nil
        Task {
            do { try await state.microsoftSignIn() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// "Running-late messages" under an account: turn it on (signs in again for the extra permission) or off.
private struct MessagingLine: View {
    let enabled: Bool
    let channels: [String]
    let enable: () async throws -> Void
    let disable: () -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane").font(.caption2)
                if enabled {
                    Text(channels.isEmpty ? "Running-late messages: permission not granted" : "Running-late messages via \(channels.joined(separator: " · "))")
                    Button("Turn Off", action: disable).buttonStyle(.link)
                } else {
                    Button(busy ? "Waiting for browser…" : "Allow running-late messages…") {
                        busy = true
                        error = nil
                        Task {
                            do { try await enable() } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }
                    .buttonStyle(.link)
                    .disabled(busy)
                    .help("Sign in again to let Cadence send \"running late\" messages as you, only when you click Send")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let error { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
        }
    }
}

private struct SlackSection: View {
    @Environment(AppState.self) private var state
    @State private var clientID = UserDefaults.standard.string(forKey: "Cadence.slack.clientID") ?? ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingSignOut: SlackAccount?

    private var auth: SlackAuth { state.slackAuth }

    var body: some View {
        Section {
            ForEach(auth.accounts) { account in
                HStack(spacing: 10) {
                    Image(systemName: "number.square.fill").font(.system(size: 18)).foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label)
                        Text(auth.needsReconnect.contains(account.id) ? "Needs signing in again" : "Can post running-late messages as you")
                            .font(.caption)
                            .foregroundStyle(auth.needsReconnect.contains(account.id) ? Color.orange : Color.secondary)
                    }
                    Spacer()
                    if auth.needsReconnect.contains(account.id) { Button("Reconnect", action: signIn).disabled(busy) }
                    Button("Sign Out") { confirmingSignOut = account }
                }
            }
            if !auth.hasBundledClient {
                TextField("Slack app client ID", text: $clientID, prompt: Text("1234567890.1234567890"))
            }
            HStack {
                Button(action: signIn) {
                    Label(busy ? "Waiting for browser…" : (auth.accounts.isEmpty ? "Sign in with Slack" : "Add Another Workspace"),
                          systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(busy || (!auth.hasBundledClient && clientID.trimmingCharacters(in: .whitespaces).isEmpty))
                if busy { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "number.square.fill").foregroundStyle(.purple)
                Text("Slack")
            }
        } footer: {
            Text("Optional — lets running-late messages for Slack huddles go to the huddle's channel, as you."
                 + (auth.hasBundledClient ? "" : " Needs a Slack app with PKCE turned on, the user scopes chat:write, users:read, users:read.email and im:write, and the redirect URL \(SlackAuth.redirect) — see the README."))
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Sign out of \(confirmingSignOut?.label ?? "")?", isPresented: Binding(
            get: { confirmingSignOut != nil }, set: { if !$0 { confirmingSignOut = nil } })
        ) {
            Button("Sign Out", role: .destructive) {
                if let account = confirmingSignOut { auth.signOut(account) }
            }
        } message: {
            Text("Cadence can no longer post running-late messages to its huddles. You can add it again any time.")
        }
    }

    private func signIn() {
        if !auth.hasBundledClient { auth.saveClientID(clientID) }
        busy = true
        error = nil
        Task {
            do { try await auth.signIn() } catch { self.error = error.localizedDescription }
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
            BadgedHeader(kind: .ics, title: "Subscribed calendars (ICS)")
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
