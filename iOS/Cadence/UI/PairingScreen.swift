import AVFoundation
import CadenceCore
import SwiftUI
import VisionKit

/// Pair with the Mac by scanning the QR code from Cadence → Settings → iPhone (or pasting its link).
struct PairingScreen: View {
    @Environment(PhoneState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On your Mac, open Cadence → Settings → iPhone → Show Pairing Code, then scan it here.")
                        .font(.callout)
                }
                if DataScannerViewController.isSupported {
                    Section("Scan") {
                        QRScanner { code in pair(code) }
                            .frame(height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .listRowInsets(EdgeInsets())
                    }
                }
                Section("Or paste the link") {
                    TextField("cadence-pair://…", text: $pasted, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button("Pair") { pair(pasted) }.disabled(pasted.isEmpty)
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func pair(_ text: String) {
        guard let invite = PairingInvite(string: text) else {
            error = "That isn't a Cadence pairing link."
            return
        }
        state.link.pair(invite)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    var found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard !done, case .barcode(let code) = item, let value = code.payloadStringValue,
                      value.hasPrefix(PairingInvite.scheme) else { continue }
                done = true
                scanner.stopScanning()
                found(value)
            }
        }
    }
}
