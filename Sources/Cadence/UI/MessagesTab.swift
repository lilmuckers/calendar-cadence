import CadenceCore
import SwiftUI

/// Settings → Messages: what the "running late" message says and where it goes.
struct MessagesTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Toggle(isOn: $state.prefs.lateMessages.enabled) {
                    Text("Offer to send a \"running late\" message")
                    Text("Once a meeting starts, the full-screen alert suggests one. Nothing is sent until you click Send.")
                }
                Picker("Say I'll be there in", selection: $state.prefs.lateMessages.defaultMinutes) {
                    ForEach(LateMessageSettings.minuteChoices, id: \.self) { Text(RunningLate.minutesText($0)).tag($0) }
                }
                .disabled(!state.prefs.lateMessages.enabled)
                LabeledContent("Can send from") {
                    Text(senders).foregroundStyle(state.lateMessenger.isSetUp ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Running late")
            }

            Group {
                SuggestionsSection()
                OwnMessagesSection()
                RoutingSection()
                DomainRulesSection()
            }
            .disabled(!state.prefs.lateMessages.enabled)
        }
        .formStyle(.grouped)
    }

    private var senders: String {
        let ready = state.lateMessenger.accounts.filter { $0.canMail || $0.canChat }.map(\.label)
        return ready.isEmpty ? "Nothing yet — Settings → Accounts → Allow running-late messages" : ready.joined(separator: ", ")
    }
}

/// The message Cadence suggests for each situation.
private struct SuggestionsSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Section {
            MessageField(title: "Previous meeting overran", detail: "It's still running, or you're still on a call.",
                         text: $state.prefs.lateMessages.overrun)
            Toggle(isOn: $state.prefs.lateMessages.mentionName) {
                Text("Mention who I'm with after a 1:1")
                Text("Tells this meeting who you were just with — off by default.")
            }
            MessageField(title: "…after a 1:1", detail: "Names who you were with.",
                         text: $state.prefs.lateMessages.overrunWithName)
                .disabled(!state.prefs.lateMessages.mentionName)
            MessageField(title: "Back-to-back", detail: "The previous meeting ended right as this one started.",
                         text: $state.prefs.lateMessages.breather)
            MessageField(title: "Just late", detail: "Nothing before it.", text: $state.prefs.lateMessages.late)
        } header: {
            Text("Suggested messages")
        } footer: {
            Text("{mins} becomes \"2 mins\" (or whatever you pick); {name} is the person from your previous 1:1.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct MessageField: View {
    let title: String
    let detail: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            TextField(title, text: $text).labelsHidden().textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }
}

/// Extra messages to pick from on the alert.
private struct OwnMessagesSection: View {
    @Environment(AppState.self) private var state
    @State private var newMessage = ""

    var body: some View {
        @Bindable var state = state
        Section {
            ForEach(state.prefs.lateMessages.custom.indices, id: \.self) { i in
                HStack {
                    TextField("Message", text: $state.prefs.lateMessages.custom[i]).labelsHidden().textFieldStyle(.roundedBorder)
                    Button {
                        state.prefs.lateMessages.custom.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this message")
                }
            }
            HStack {
                TextField("New message", text: $newMessage, prompt: Text("Be right there — {mins}!"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newMessage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Your messages")
        } footer: {
            Text("Offered alongside the suggestion. You can always write something one-off on the alert itself.")
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let text = newMessage.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        state.prefs.lateMessages.custom.append(text)
        newMessage = ""
    }
}

/// How the best guess is picked. Read-only: the meeting's link decides first.
private struct RoutingSection: View {
    var body: some View {
        Section {
            route("video", "Teams meeting", "Its meeting chat")
            route("video", "Google Meet", "Google Chat — a group chat for up to \(RunningLate.groupChatLimit) people in one organisation, otherwise the organiser")
            route("headphones", "Slack huddle", "The huddle's channel")
            route("questionmark.circle", "Anything else", "Your domain rule below, then email to the organiser")
        } header: {
            Text("Where it goes")
        } footer: {
            Text("It's sent from the account the meeting is for: the one matching its browser profile (Settings → Browser), then the one its calendar belongs to. The alert lists every other option, checked, so you can change it.")
                .foregroundStyle(.secondary)
        }
    }

    private func route(_ symbol: String, _ title: String, _ target: String) -> some View {
        LabeledContent {
            Text(target).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

/// Domain → channel (and account), for meetings whose link doesn't decide.
private struct DomainRulesSection: View {
    @Environment(AppState.self) private var state
    @State private var newDomain = ""

    var body: some View {
        @Bindable var state = state
        Section {
            ForEach($state.prefs.lateMessages.domainRules) { $rule in
                HStack(spacing: 8) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("Domain", text: $rule.domain).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 150)
                    Picker("Channel", selection: $rule.channel) {
                        ForEach(LateChannelKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .onChange(of: rule.channel) { _, _ in
                        if let id = rule.accountID, !accounts(for: rule.channel).contains(where: { $0.id == id }) { rule.accountID = nil }
                    }
                    Picker("From", selection: $rule.accountID) {
                        Text("Best guess").tag(String?.none)
                        ForEach(accounts(for: rule.channel), id: \.id) { a in
                            Text(a.label + (a.canChat || a.canMail ? "" : " (not allowed yet)")).tag(Optional(a.id))
                        }
                    }
                    .labelsHidden()
                    Button {
                        state.prefs.lateMessages.domainRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove rule")
                }
            }
            HStack {
                TextField("Domain", text: $newDomain, prompt: Text("client.com")).labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add Rule", action: add).disabled(cleaned.isEmpty)
            }
        } header: {
            Text("Domain rules")
        } footer: {
            Text("Matched against the organiser's address, then the domain most attendees share, subdomains included. The first matching rule wins.")
                .foregroundStyle(.secondary)
        }
    }

    private var cleaned: String {
        newDomain.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
    }

    private func accounts(for channel: LateChannelKind) -> [MessagingAccount] {
        state.lateMessenger.accounts.filter { a in
            switch channel {
            case .teams: a.kind == .microsoft
            case .googleChat: a.kind == .google
            case .slack: a.kind == .slack
            case .email: a.kind != .slack
            }
        }
    }

    private func add() {
        guard !cleaned.isEmpty else { return }
        state.prefs.lateMessages.domainRules.append(LateDomainRule(domain: cleaned, channel: .email))
        newDomain = ""
    }
}
