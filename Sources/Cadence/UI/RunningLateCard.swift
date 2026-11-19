import CadenceCore
import SwiftUI

/// On the full-screen alert once a meeting has started: where to send (best guess, with every other
/// option checked and listed), what to say (suggestion, your saved messages, or your own words), how long,
/// and Send — which posts it as you and holds the alert off until then.
struct RunningLateCard: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    let afterSend: () -> Void

    @State private var minutes = 2
    @State private var draft: AppState.LateDraft?
    @State private var channelID: String?
    /// The user picked a channel themselves, so checks finishing don't move the selection.
    @State private var channelChosen = false
    @State private var checks: [String: LateMessenger.Check] = [:]
    /// Index into draft.messages, or nil when writing your own.
    @State private var messageIndex: Int? = 0
    @State private var ownText = ""
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var ownFocused: Bool

    private var channel: LateOption? { draft?.channels.first { $0.id == channelID } }
    private var text: String {
        if let i = messageIndex, let messages = draft?.messages, messages.indices.contains(i) { return messages[i] }
        return ownText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        // A real container, not a Group: modifiers on a Group go to its children, so while there's no draft
        // yet (no children) its onAppear never ran, the draft was never built and the card stayed blank.
        VStack(spacing: 0) {
            if let notice = state.lateNotices[meeting.id] {
                sent(notice)
            } else if !state.lateMessenger.isSetUp {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane")
                    Text("Running late? Allow running-late messages for an account in Settings → Accounts, and Cadence can tell them for you.")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            } else if let draft {
                compose(draft)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: 640)
        .onAppear {
            minutes = state.prefs.lateMessages.defaultMinutes
            rebuild()
            checkChannels()
        }
    }

    // MARK: Compose

    private func compose(_ draft: AppState.LateDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                Text("Running late? Let them know").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.85))

            row("Send via") { channelMenu(draft) }
            row("Message") { messageMenu(draft) }
            if messageIndex == nil {
                row("") {
                    TextField("Write your own", text: $ownText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1...3)
                        .focused($ownFocused)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                }
            }

            HStack(spacing: 10) {
                Picker("", selection: $minutes) {
                    ForEach(LateMessageSettings.minuteChoices, id: \.self) { Text(RunningLate.minutesText($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                .onChange(of: minutes) { _, _ in rebuild() }
                if let failure {
                    Text(failure).font(.system(size: 12)).foregroundStyle(.red.opacity(0.9)).lineLimit(2)
                }
                Spacer()
                Button(action: send) {
                    HStack(spacing: 6) {
                        if sending { ProgressView().controlSize(.small) } else { Image(systemName: "paperplane.fill") }
                        Text(sending ? "Sending…" : "Send")
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(PressableStyle())
                .disabled(sending || text.isEmpty || channel == nil || channel?.blocked != nil
                          || { if case .unavailable = checks[channelID ?? ""] { true } else { false } }())
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
    }

    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 70, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func channelMenu(_ draft: AppState.LateDraft) -> some View {
        Menu {
            ForEach(draft.channels) { option in
                Button {
                    channelID = option.id
                    channelChosen = true
                    failure = nil
                } label: {
                    Label("\(option.label) — \(option.accountLabel)\(statusSuffix(option))", systemImage: statusIcon(option))
                }
                .disabled(!usable(option))
            }
            if draft.channels.isEmpty { Text("Nothing you're signed in to can reach them") }
            Divider()
            SettingsLink { Text("Domain Rules & Accounts…") }
        } label: {
            HStack(spacing: 6) {
                if let channel {
                    Image(systemName: statusIcon(channel))
                    Text(channel.label).fontWeight(.semibold)
                    Text("from \(channel.accountLabel)").foregroundStyle(.white.opacity(0.55))
                    if case .ready(let note?) = checks[channel.id] { Text("· \(note)").foregroundStyle(.white.opacity(0.45)) }
                    if case .unavailable(let why) = checks[channel.id] { Text("· \(why)").foregroundStyle(.orange) }
                } else {
                    Text("Nowhere to send it")
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func messageMenu(_ draft: AppState.LateDraft) -> some View {
        Menu {
            ForEach(Array(draft.messages.enumerated()), id: \.offset) { i, message in
                Button {
                    messageIndex = i
                } label: {
                    if i == 0 { Label(message, systemImage: "sparkles") } else { Text(message) }
                }
            }
            Divider()
            Button("Write My Own…") {
                if ownText.isEmpty { ownText = text }
                messageIndex = nil
                ownFocused = true
            }
            SettingsLink { Text("Edit Saved Messages…") }
        } label: {
            Text(messageIndex == nil ? "Your own words" : text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: Status

    private func usable(_ option: LateOption) -> Bool {
        if option.blocked != nil { return false }
        if case .unavailable = checks[option.id] { return false }
        return true
    }

    private func statusIcon(_ option: LateOption) -> String {
        if option.blocked != nil { return "lock" }
        switch checks[option.id] {
        case .ready?: return "checkmark.circle"
        case .unavailable?: return "exclamationmark.triangle"
        default: return "circle.dotted"
        }
    }

    private func statusSuffix(_ option: LateOption) -> String {
        if let blocked = option.blocked { return " (\(blocked))" }
        switch checks[option.id] {
        case .ready(let note?)?: return " (\(note))"
        case .unavailable(let why)?: return " (\(why))"
        case .checking?, nil: return " (checking…)"
        default: return ""
        }
    }

    // MARK: Actions

    /// New suggestions for the chosen minutes; keeps the channel and your own words.
    private func rebuild() {
        let d = state.lateDraft(for: meeting, minutes: minutes)
        draft = d
        if channelID == nil || !d.channels.contains(where: { $0.id == channelID }) {
            channelID = d.channels.first { $0.blocked == nil }?.id ?? d.channels.first?.id
        }
        if let i = messageIndex, i >= d.messages.count { messageIndex = 0 }
    }

    /// Ask each service whether its option will work; if the best guess can't, move to the next one that can.
    private func checkChannels() {
        guard let options = draft?.channels.filter({ $0.blocked == nil }).prefix(8) else { return }
        for option in options {
            if let cached = state.lateMessenger.cachedCheck(option) { checks[option.id] = cached; continue }
            checks[option.id] = .checking
            Task {
                let result = await state.lateMessenger.check(option)
                checks[option.id] = result
                reselectIfNeeded()
            }
        }
        reselectIfNeeded()
    }

    private func reselectIfNeeded() {
        guard !channelChosen, let draft, let current = channel, !usable(current) else { return }
        if let next = draft.channels.first(where: { usable($0) && checks[$0.id]?.isUsable == true })
            ?? draft.channels.first(where: usable) {
            channelID = next.id
        }
    }

    private func sent(_ notice: AppState.LateNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Told them via \(notice.via) — you said you'd be there by \(notice.promised.formatted(date: .omitted, time: .shortened)).")
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white.opacity(0.8))
    }

    private func send() {
        guard let channel else { return }
        sending = true
        failure = nil
        let message = text
        Task {
            do {
                try await state.sendLateMessage(message, minutes: minutes, via: channel, for: meeting)
                sending = false
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                afterSend()
            } catch {
                sending = false
                failure = LateMessenger.short(error)
                checks[channel.id] = .unavailable(LateMessenger.short(error))
            }
        }
    }
}

/// Right-click "Send Running Late" submenu: pick a message and it's sent straight away (as you) via the
/// best-guess channel, with your default delay. Offered from a little before the start until the end.
struct RunningLateMenu: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting

    var body: some View {
        if state.prefs.lateMessages.enabled, !meeting.isAllDay,
           meeting.start.timeIntervalSince(state.now) < 15 * 60, meeting.end > state.now {
            let minutes = state.prefs.lateMessages.defaultMinutes
            let draft = state.lateDraft(for: meeting, minutes: minutes)
            Menu("Send Running Late") {
                if !state.lateMessenger.isSetUp {
                    SettingsLink { Text("Set Up in Settings → Accounts…") }
                } else if let option = draft.channels.first(where: { $0.blocked == nil }) {
                    Text("Via \(option.label) from \(option.accountLabel)")
                    ForEach(draft.messages, id: \.self) { message in
                        Button(message) {
                            Task {
                                do {
                                    try await state.sendLateMessage(message, minutes: minutes, via: option, for: meeting)
                                    state.notifyLateOutcome(nil, option: option, meeting: meeting)
                                } catch {
                                    state.notifyLateOutcome(error, option: option, meeting: meeting)
                                }
                            }
                        }
                    }
                } else {
                    Text("Nothing you're signed in to can reach them")
                }
            }
        }
    }
}
