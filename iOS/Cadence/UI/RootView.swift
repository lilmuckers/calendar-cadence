import CadenceCore
import SwiftUI

struct RootView: View {
    @Environment(PhoneState.self) private var state
    @State private var showSettings = false
    @State private var showPairing = false

    var body: some View {
        ZStack {
            if state.desk.isOn {
                DeskView { state.desk.set(false) }
                    .transition(.opacity)
            } else {
                AgendaScreen(showSettings: $showSettings, showPairing: $showPairing)
                    .transition(.opacity)
            }
            if !state.desk.isOn {
                // Desk mode places the strip itself (bottom in portrait, agenda column in landscape).
                VStack { Spacer(); PromptStrip(style: .strip) }
                    .zIndex(5)
            }
            if let alerting = state.alerting {
                AlertOverlay(meeting: alerting)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(10)
            }
        }
        .animation(Theme.spring, value: state.desk.isOn)
        .animation(Theme.spring, value: state.alerting?.id)
        .sheet(isPresented: $showSettings) { SettingsScreen() }
        .sheet(isPresented: $showPairing) { PairingScreen() }
    }
}

/// The normal (not-on-a-stand) screen: today's agenda, with desk mode one tap away.
private struct AgendaScreen: View {
    @Environment(PhoneState.self) private var state
    @Binding var showSettings: Bool
    @Binding var showPairing: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { state.desk.set(true) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                                .font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Desk mode").font(.headline)
                                Text(state.prefs.deskWhenCharging ? "Turns on by itself while charging, e.g. on a MagSafe stand."
                                     : "Keep the countdown on screen.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    macRow
                }

                if !state.hasOwnSources && !state.usingMac && state.snapshot == nil {
                    Section {
                        Text("Connect a calendar or pair with Cadence on your Mac to see your meetings.")
                            .foregroundStyle(.secondary)
                        Button("Connect calendars…") { showSettings = true }
                    }
                }

                Section {
                    if state.usingMacCopy, let saved = state.macCopyDate {
                        Text(state.link.links.count > 1
                             ? "Your Macs are out of reach. This is their agenda from \(Self.savedText(saved)); alerts and Join still work here."
                             : "\(state.link.mac?.displayName ?? "Mac") is out of reach. This is its agenda from \(Self.savedText(saved)); alerts and Join still work here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if state.todayMeetings.isEmpty {
                        Text("No meetings today.").foregroundStyle(.secondary)
                    }
                    ForEach(state.todayMeetings) { MeetingRow(meeting: $0) }
                } header: {
                    Text(state.usingMac || state.usingMacCopy ? "Today · from \(agendaSource)" : "Today")
                }
            }
            .navigationTitle("Cadence")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await state.refreshRemote() }
        }
    }

    /// "Work laptop", or "Work laptop & Home iMac" with several Macs behind the agenda.
    private var agendaSource: String {
        let names = state.agenda.agendas.compactMap { a in state.link.link(a.macID)?.mac.displayName }
        return names.isEmpty ? state.link.mac?.displayName ?? "Mac" : names.formatted(.list(type: .and))
    }

    @ViewBuilder private var macRow: some View {
        if state.link.links.isEmpty {
            Button { showPairing = true } label: {
                Label("Pair with Cadence on your Mac", systemImage: "laptopcomputer.and.iphone")
            }
        } else {
            ForEach(state.link.links) { mac in
                HStack {
                    Label(mac.mac.displayName, systemImage: "laptopcomputer")
                    Spacer()
                    Text(statusText(mac)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if state.link.needsRescan {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Can't reach your Mac. Make sure Cadence is open on it and you're on the same Wi-Fi, or scan its pairing code again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Scan Pairing Code") { showPairing = true }.font(.callout)
                }
            }
        }
    }

    /// "14:05", or "Tue 14:05" when it's from an earlier day.
    private static func savedText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func statusText(_ mac: MacLink) -> String {
        switch mac.status {
        case .connected: state.link.connected.first === mac ? "Connected · Join opens on the Mac" : "Connected"
        case .connecting: "Connecting…"
        case .searching: "Looking…"
        case .failed(let why): why
        case .off: "Not connected"
        case .unpaired: "Pairing key missing — pair again"
        }
    }
}
