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

                Section(state.usingMac ? "Today · from \(state.link.mac?.name ?? "Mac")" : "Today") {
                    if state.todayMeetings.isEmpty {
                        Text("No meetings today.").foregroundStyle(.secondary)
                    }
                    ForEach(state.todayMeetings) { MeetingRow(meeting: $0) }
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

    @ViewBuilder private var macRow: some View {
        if state.link.mac == nil {
            Button { showPairing = true } label: {
                Label("Pair with Cadence on your Mac", systemImage: "laptopcomputer.and.iphone")
            }
        } else {
            HStack {
                Label(state.link.mac?.name ?? "Mac", systemImage: "laptopcomputer")
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
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

    private var statusText: String {
        switch state.link.status {
        case .connected: "Connected · Join opens on the Mac"
        case .connecting: "Connecting…"
        case .searching: "Looking…"
        case .failed(let why): why
        case .off: "Not connected"
        case .unpaired: "Pairing key missing — pair again"
        }
    }
}
