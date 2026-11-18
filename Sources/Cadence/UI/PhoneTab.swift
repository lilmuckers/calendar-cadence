import AppKit
import CadenceCore
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings → iPhone: pair a phone, see whether it's displaying, choose what the Mac still shows.
struct PhoneTab: View {
    @Environment(AppState.self) private var state
    @State private var invite: PairingInvite?
    @State private var confirmForget = false

    var body: some View {
        @Bindable var state = state
        let hub = state.companion
        Form {
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
                Section("While the iPhone is displaying") {
                    Picker("Full-screen alert", selection: $state.prefs.companionTakeover) {
                        ForEach(CompanionTakeoverMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text("Join on the phone joins on this Mac while they're connected.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Pairing") {
                    if let invite {
                        PairingCard(invite: invite) { self.invite = nil }
                    } else {
                        LabeledContent("Pair an iPhone") {
                            Button("Show Pairing Code…") { invite = hub.invite() }
                        }
                    }
                    if !hub.paired.isEmpty {
                        ForEach(hub.paired) { phone in
                            LabeledContent {
                                Text(hub.phones.contains { $0.id == phone.id }
                                     ? "Connected"
                                     : "Last seen \(phone.lastSeen.formatted(.relative(presentation: .named)))")
                                    .foregroundStyle(.secondary)
                            } label: {
                                Label(phone.name, systemImage: "iphone")
                            }
                        }
                        Button("Forget All iPhones…", role: .destructive) { confirmForget = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget every paired iPhone?", isPresented: $confirmForget) {
            Button("Forget All", role: .destructive) {
                invite = nil
                state.companion.forgetAllPhones()
            }
        } message: {
            Text("They disconnect now and need to scan a new code to pair again.")
        }
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
        if let displaying = hub.phones.first(where: \.displaying) { return "\(displaying.name) is displaying — Mac is quiet" }
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
                Text("Anyone who can see this code can pair, so close it when you're done.")
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
