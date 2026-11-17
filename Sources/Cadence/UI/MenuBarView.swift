import AppKit
import CadenceCore
import SwiftUI

/// Text shown next to the menu bar icon, e.g. "12m Standup".
struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if state.prefs.showMenuBarTitle, let text {
                Text(text).monospacedDigit()
            }
        }
    }

    private var symbol: String {
        if let next = state.next, next.start.timeIntervalSince(state.now) <= 300 { return "calendar.badge.clock" }
        return "calendar"
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
        switch state.access {
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
            if state.todayMeetings.isEmpty {
                EmptyState(symbol: "sun.max", title: "Nothing today", message: tomorrowHint, actionTitle: nil, action: {})
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(state.todayMeetings) { meeting in
                            EventRow(meeting: meeting, expanded: expanded == meeting.id) {
                                withAnimation(Theme.spring) { expanded = expanded == meeting.id ? nil : meeting.id }
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)
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
            Toggle(isOn: Binding(get: { state.prefs.showPanel }, set: { state.prefs.showPanel = $0 })) {
                Text("Countdown panel").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Refresh") { state.refresh() }
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
