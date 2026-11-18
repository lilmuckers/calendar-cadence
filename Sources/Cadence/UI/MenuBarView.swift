import AppKit
import CadenceCore
import SwiftUI

/// Text shown next to the menu bar icon, e.g. "12m Standup".
struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(mood, phone: phone))
            if state.prefs.showMenuBarTitle, let text {
                Text(text).monospacedDigit()
            }
        }
    }

    /// A paired iPhone: connected, or on the desk showing Cadence (the Mac is quiet).
    private var phone: MenuBarIcon.Phone {
        let hub = state.companion
        if hub.phoneDisplaying { return .displaying }
        return hub.isConnected ? .connected : .none
    }

    /// Gets more anxious as the next meeting approaches.
    private var mood: MenuBarIcon.Mood {
        switch IconMood.forNext(start: state.next?.start, now: state.now) {
        case .calm: .calm
        case .nervous: .nervous
        case .panicking: .panicking
        }
    }

    private var text: String? {
        if let next = state.next, next.start.timeIntervalSince(state.now) <= 3600 {
            return "\(CountdownFormatter.short(next.start.timeIntervalSince(state.now))) · \(truncate(next.title))"
        }
        if let cur = state.current.first {
            return "\(truncate(cur.title)) · \(CountdownFormatter.short(cur.end.timeIntervalSince(state.now))) left"
        }
        return nil
    }

    private func truncate(_ s: String, to n: Int = 22) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }
}

/// The dropdown: today's agenda.
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @State private var expanded: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 380)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.now.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Text(state.now.formatted(.dateTime.month(.wide).day()))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }
            Spacer()
            if !state.invites.isEmpty {
                Button { state.reviewInvites() } label: {
                    Label("\(state.invites.count)", systemImage: "envelope.badge")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help("\(state.invites.count) invite\(state.invites.count == 1 ? "" : "s") waiting for a reply")
                .padding(.trailing, 6)
            }
            if let next = state.next, state.isNextToday {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Next in")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(CountdownFormatter.clock(next.start.timeIntervalSince(state.now)))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(next.tint)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.default, value: Int(state.now.timeIntervalSince1970))
                }
            } else if !state.todayMeetings.isEmpty {
                Text("All done for today")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state.canShowAgenda ? .granted : state.access {
        case .denied:
            EmptyState(
                symbol: "lock.shield",
                title: "Calendar access needed",
                message: "Cadence reads the accounts you've added to macOS Calendar — iCloud, Google, Exchange and more.",
                actionTitle: "Open Privacy Settings",
                action: state.openPrivacySettings
            )
        case .unknown:
            EmptyState(symbol: "calendar", title: "Connecting…", message: "Waiting for calendar access.",
                       actionTitle: "Grant Access", action: { Task { await state.requestAccess() } })
        case .granted:
            if state.todayMeetings.isEmpty && !state.showsTomorrow {
                EmptyState(symbol: "sun.max", title: "Nothing today", message: tomorrowHint, actionTitle: nil, action: {})
            } else {
                if Self.screenshotMode {
                    // ImageRenderer can't draw ScrollView contents.
                    agenda
                } else {
                    ScrollView { agenda }
                        .frame(maxHeight: 520)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static var screenshotMode = false

    private var agenda: some View {
        LazyVStack(spacing: 4) {
            if state.todayMeetings.isEmpty {
                Text("Nothing else today")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            rows(state.todayMeetings)
            if state.showsTomorrow {
                HStack(spacing: 6) {
                    Text("TOMORROW")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                    Text(state.tomorrowMeetings.first.map { $0.start.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)) } ?? "")
                        .font(.system(size: 10, weight: .medium))
                    Rectangle().fill(.primary.opacity(0.1)).frame(height: 1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, state.todayMeetings.isEmpty ? 0 : 10)
                .padding(.bottom, 2)
                rows(state.tomorrowMeetings)
            }
        }
        .padding(10)
    }

    private func rows(_ meetings: [Meeting]) -> some View {
        ForEach(meetings) { meeting in
            EventRow(meeting: meeting, expanded: expanded == meeting.id) {
                withAnimation(Theme.spring) { expanded = expanded == meeting.id ? nil : meeting.id }
            }
        }
    }

    private var tomorrowHint: String {
        if let next = state.next { return "Next: \(next.title), \(next.start.formatted(.relative(presentation: .named)))." }
        return "Your filtered calendars are clear."
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            if Self.screenshotMode {
                // ImageRenderer can't draw AppKit-backed switches; fake one for README images.
                HStack(spacing: 8) {
                    Text("Countdown panel").font(.system(size: 12))
                    Capsule().fill(Color.accentColor).frame(width: 26, height: 15)
                        .overlay(alignment: .trailing) { Circle().fill(.white).padding(2) }
                }
            } else {
                Toggle(isOn: Binding(get: { state.prefs.showPanel }, set: { state.prefs.showPanel = $0 })) {
                    Text("Countdown panel").font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await state.refreshRemote() } }
            IconButton(symbol: "gearshape", help: "Settings") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            IconButton(symbol: "power", help: "Quit Cadence") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle {
                Button(actionTitle, action: action).controlSize(.small).padding(.top, 4)
            }
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }
}
