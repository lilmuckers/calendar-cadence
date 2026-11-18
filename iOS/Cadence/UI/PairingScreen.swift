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
    @State private var camera: CameraAccess = .unknown

    enum CameraAccess { case unknown, allowed, denied }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On your Mac, open Cadence → Settings → iPhone → Show Pairing Code, then scan it here.")
                        .font(.callout)
                }
                if DataScannerViewController.isSupported {
                    Section("Scan") {
                        switch camera {
                        case .allowed:
                            QRScanner { code in pair(code) }
                                .frame(height: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .listRowInsets(EdgeInsets())
                        case .denied:
                            Text("Cadence can't use the camera. Allow it in Settings → Cadence → Camera, or paste the link below.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        case .unknown:
                            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                        }
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
            .task { camera = await Self.cameraAccess() }
        }
    }

    /// The scanner shows nothing (and starting it fails) until the camera is allowed, so ask first.
    private static func cameraAccess() async -> CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
        default: return .denied
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

    func makeUIViewController(context: Context) -> ScannerHost {
        let host = ScannerHost()
        host.scanner.delegate = context.coordinator
        return host
    }

    func updateUIViewController(_ host: ScannerHost, context: Context) {}

    static func dismantleUIViewController(_ host: ScannerHost, coordinator: Coordinator) {
        host.scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    /// Holds the scanner as a child and starts it in viewDidAppear: starting it any earlier throws,
    /// and the box stays black.
    final class ScannerHost: UIViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !scanner.isScanning else { return }
            do { try scanner.startScanning() } catch { print("QR scanner didn't start: \(error)") }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            scanner.stopScanning()
        }
    }

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

        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            print("QR scanner unavailable: \(error)")
        }
    }
}
