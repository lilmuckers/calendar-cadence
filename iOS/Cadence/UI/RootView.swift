import CadenceCore
import SwiftUI
import TipKit

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
        .fullScreenCover(isPresented: welcomeShown) {
            WelcomeView()
                // A pairing link opened during the welcome still asks first.
                .alert(pairingTitle, isPresented: pairingAsked, presenting: state.pendingInvite) { _ in
                    Button("Pair") { state.confirmPendingPairing() }
                    Button("Cancel", role: .cancel) { state.pendingInvite = nil }
                } message: { _ in Text(pairingMessage) }
        }
        .alert(pairingTitle, isPresented: pairingAsked, presenting: state.pendingInvite) { _ in
            Button("Pair") { state.confirmPendingPairing() }
            Button("Cancel", role: .cancel) { state.pendingInvite = nil }
        } message: { _ in Text(pairingMessage) }
    }

    private var pairingMessage: String {
        "Only pair with a Mac you own. It will send this iPhone its calendar and alerts, and see what's playing here."
    }

    private var welcomeShown: Binding<Bool> {
        Binding(get: { !state.prefs.welcomeSeen }, set: { if !$0 { state.prefs.welcomeSeen = true } })
    }

    private var pairingTitle: String {
        "Pair with \(state.pendingInvite?.macName ?? "this Mac")?"
    }

    private var pairingAsked: Binding<Bool> {
        Binding(get: { state.pendingInvite != nil }, set: { if !$0 { state.pendingInvite = nil } })
    }
}

/// The normal (not-on-a-stand) screen: today's agenda, with desk mode one tap away.
private struct AgendaScreen: View {
    @Environment(PhoneState.self) private var state
    @Binding var showSettings: Bool
    @Binding var showPairing: Bool

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    EmptyHome(showSettings: $showSettings, showPairing: $showPairing)
                        .transition(.opacity)
                } else {
                    agenda.transition(.opacity)
                }
            }
            .animation(Theme.spring, value: isEmpty)
            .navigationTitle("Cadence")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
        }
    }

    /// Nothing connected and nothing saved from a Mac: the designed empty screen, not a bare list.
    private var isEmpty: Bool { !state.hasRealSource && !state.usingSample && state.snapshot == nil }

    private var agenda: some View {
        List {
            Section {
                DeskTile { state.desk.set(true); CadenceTips.desk.invalidate(reason: .actionPerformed) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                TipView(CadenceTips.desk)
                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                TipView(CadenceTips.refresh)
                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            .listSectionSpacing(14)

            Section { macRow }

            if state.usingSample {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sample meetings").font(.subheadline.weight(.semibold))
                            Text("Made up, to show how Cadence works. Connecting a calendar removes them.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("Remove") { withAnimation(Theme.spring) { state.setSample(false) } }
                            .font(.callout).buttonStyle(.borderless)
                    }
                    Button("Connect a Calendar…") { showSettings = true }
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
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No meetings today.").foregroundStyle(.secondary)
                        if let next = state.next {
                            Text("Next: \(Self.nextText(next.start)) · \(next.title)")
                                .font(.subheadline.weight(.medium)).lineLimit(1)
                        }
                    }
                }
                ForEach(state.todayMeetings) { MeetingRow(meeting: $0) }
            } header: {
                Text(state.usingMac || state.usingMacCopy ? "Today · from \(agendaSource)" : "Today")
            }
        }
        .animation(Theme.spring, value: state.todayMeetings.map(\.id))
        .refreshable {
            CadenceTips.refresh.invalidate(reason: .actionPerformed)
            await state.refreshRemote()
        }
        .onChange(of: state.hasRealSource || state.usingSample, initial: true) { _, has in
            CadenceTips.hasMeetings = has
        }
        .task {
            // The refresh tip waits until the desk tip has gone, so only one shows at a time.
            for await status in CadenceTips.desk.statusUpdates {
                if case .invalidated = status { CadenceTips.deskTipDone = true }
            }
        }
    }

    /// "Tomorrow 09:00", or "Thu 09:00" further out.
    private static func nextText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
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
            if state.link.status == .noLocalNetwork {
                LocalNetworkHelp()
            } else if state.link.needsRescan {
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
        case .connected:
            (state.link.connected.first === mac ? "Connected · Join opens on the Mac" : "Connected")
                + (mac.transport == .bluetooth ? " · Bluetooth" : "")
        case .failed(let why): why
        default: mac.status.label
        }
    }
}

/// Shown when Local Network access is off: without it Cadence can't find or reach the Mac.
struct LocalNetworkHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cadence needs Local Network access to find your Mac. Turn it on in Settings → Apps → Cadence → Local Network.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.callout)
        }
    }
}
