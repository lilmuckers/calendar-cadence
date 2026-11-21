import AppKit
import CadenceCore
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings → iPhone: pair a phone, see whether it's displaying, choose what the Mac still shows.
struct PhoneTab: View {
    @Environment(AppState.self) private var state
    @State private var invite: PairingInvite?
    @State private var confirmForget = false
    @State private var forgetting: PairedPhone?
    /// The paired phone whose details are open, in place of the list.
    @State private var showing: String?

    var body: some View {
        let hub = state.companion
        Group {
            // Details open inside the tab rather than in a sheet, so Settings keeps its size and the page scrolls.
            if let phone = hub.paired.first(where: { $0.id == showing }) {
                PhoneDetail(phone: phone, back: { showing = nil }, forget: { forgetting = phone })
            } else {
                list(hub: hub)
            }
        }
        // A code works once: close it when a phone pairs with it (or it expires).
        .onChange(of: state.companion.pendingKeyID) { _, keyID in if keyID == nil { invite = nil } }
        .confirmationDialog("Forget \(forgetting?.name ?? "this iPhone")?",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            presenting: forgetting) { phone in
            Button("Forget", role: .destructive) { state.companion.forget(phone.id) }
        } message: { phone in
            Text(phone.keyID == nil
                 ? "It disconnects now and needs a new code to pair again. It still uses the key every iPhone shared before this version, so any other iPhone that hasn't connected since the update needs a new code too."
                 : "It disconnects now and needs a new code to pair again. Other iPhones stay paired.")
        }
        .confirmationDialog("Forget every paired iPhone?", isPresented: $confirmForget) {
            Button("Forget All", role: .destructive) {
                invite = nil
                state.companion.forgetAllPhones()
            }
        } message: {
            Text("They disconnect now and need to scan a new code to pair again.")
        }
    }

    private func list(hub: CompanionHub) -> some View {
        @Bindable var state = state
        return Form {
            Section {
                Toggle(isOn: $state.prefs.companionEnabled) {
                    Text("Use Cadence on iPhone as a desk display")
                    Text("Put your iPhone on a stand with Cadence open and the Mac stays quiet: the countdown panel, banners and reminders move to the phone. Works over Wi-Fi, or directly between the devices when they're not on the same network.")
                }
                if state.prefs.companionEnabled {
                    LabeledContent("Status") { StatusLine(hub: hub) }
                }
            }

            if state.prefs.companionEnabled {
                Section {
                    Picker("Full-screen alert", selection: $state.prefs.companionTakeover) {
                        ForEach(CompanionTakeoverMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("If you're still late", selection: $state.prefs.companionEscalation) {
                        ForEach(CompanionEscalation.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("While the iPhone is displaying")
                } footer: {
                    Text("\"If you're still late\" brings the alert up on this Mac too once the meeting has started and you haven't joined, snoozed or dismissed it on the phone. Join on the phone joins on this Mac while they're connected.")
                        .foregroundStyle(.secondary)
                }

                PhoneMediaSection()

                Section {
                    if let invite {
                        PairingCard(invite: invite) {
                            self.invite = nil
                            hub.cancelInvite()
                        }
                    } else {
                        LabeledContent("Pair an iPhone") {
                            Button("Show Pairing Code…") { invite = hub.invite() }
                        }
                    }
                    if !hub.paired.isEmpty {
                        ForEach(hub.paired) { phone in
                            HStack(spacing: 10) {
                                // Click the phone for its details and the Advanced link analytics.
                                Button { showing = phone.id } label: {
                                    HStack {
                                        Label(phone.name, systemImage: "iphone")
                                        Spacer()
                                        Text(PhoneDetail.status(of: phone, hub: hub)).foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Details for \(phone.name)")
                                Button("Forget…") { forgetting = phone }
                                    .controlSize(.small)
                            }
                        }
                        Button("Forget All iPhones…", role: .destructive) { confirmForget = true }
                    }
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("Pair as many iPhones as you like: alerts and prompts go to all of them, and the media keys follow the one that went on display last.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One paired phone, shown inside the iPhone tab: whether it's connected, and behind Advanced,
/// what's gone over the link with it.
private struct PhoneDetail: View {
    @Environment(AppState.self) private var state
    let phone: PairedPhone
    let back: () -> Void
    let forget: () -> Void
    @AppStorage("Cadence.companion.showLinkTraffic") private var advanced = false

    var body: some View {
        let hub = state.companion
        Form {
            Section {
                LabeledContent("Status", value: Self.status(of: phone, hub: hub))
                if let connected = hub.phones.first(where: { $0.id == phone.id }) {
                    LabeledContent("On display", value: connected.displaying ? "Yes, the Mac is quiet" : "No")
                }
                LabeledContent("Key", value: phone.keyID == nil ? "Shared (older pairing)" : "Its own")
                LabeledContent("Unpair") {
                    Button("Forget…", role: .destructive, action: forget)
                }
            } header: {
                HStack {
                    Button(action: back) {
                        Label("iPhone", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Back to all iPhones")
                    Spacer()
                    Label(phone.name, systemImage: "iphone").font(.headline)
                    Spacer()
                    // Balances the back button so the name sits in the middle.
                    Label("iPhone", systemImage: "chevron.left").hidden()
                }
            }
            Section {
                Toggle(isOn: $advanced.animation()) {
                    Text("Advanced")
                    Text("What goes over the link with this iPhone: data used and each type of message over time.")
                }
            }
            if advanced {
                LinkTrafficSections(traffic: hub.traffic.traffic(for: phone.id), peer: phone.name)
            }
        }
        .formStyle(.grouped)
    }

    static func status(of phone: PairedPhone, hub: CompanionHub) -> String {
        hub.phones.contains { $0.id == phone.id }
            ? "Connected"
            : "Last seen \(phone.lastSeen.formatted(.relative(presentation: .named)))"
    }
}

private struct StatusLine: View {
    let hub: CompanionHub

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        if hub.phoneDisplaying { return .green }
        if hub.isConnected { return .blue }
        return hub.listening ? .orange : .gray
    }

    private var text: String {
        let others = hub.phones.count - 1
        let more = others > 0 ? " (+\(others) more connected)" : ""
        if let displaying = hub.phones.filter(\.displaying).max(by: { $0.since < $1.since }) {
            return "\(displaying.name) is displaying — Mac is quiet\(more)"
        }
        if hub.phones.count > 1 { return "\(hub.phones.count) iPhones connected (not on display)" }
        if let phone = hub.phones.first { return "\(phone.name) connected (not on display)" }
        if let error = hub.lastError { return "Not listening: \(error)" }
        if hub.paired.isEmpty { return "No iPhone paired yet" }
        return hub.listening ? "Waiting for iPhone…" : "Starting…"
    }
}

private struct PairingCard: View {
    let invite: PairingInvite
    let done: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let qr = Self.qrImage(invite.url.absoluteString) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 150, height: 150)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan with Cadence on your iPhone").font(.headline)
                Text("Open Cadence on the phone → Pair with Mac → Scan. Or copy the link and paste it there.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Anyone who can see this code can pair, so close it when you're done. It works once, for 15 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
                    }
                    Button("Done", action: done).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.vertical, 4)
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
