import CadenceCore
import Foundation
import Network
import Security

/// Network parameters shared by the Mac's listener and the phone's connection: TCP + TLS 1.2 with a
/// pre-shared key (the 32-byte link key from pairing), peer-to-peer allowed so the link also works
/// over AWDL when the two aren't on the same Wi-Fi.
enum CompanionNetwork {
    static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("cadence".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.noDelay = true

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}

/// One framed, encrypted connection between the Mac and a phone. Pings while open and closes itself
/// after `CompanionService.timeout` of silence. Everything runs on the main queue.
@MainActor
final class CompanionChannel {
    let connection: NWConnection
    var onMessage: ((CompanionMessage) -> Void)?
    var onReady: (() -> Void)?
    /// Called once, when the channel is gone for good.
    var onClose: ((Error?) -> Void)?

    private var decoder = CompanionFrameDecoder()
    /// When anything (pings included) last arrived.
    private(set) var lastHeard = Date()
    private var pinger: Timer?
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            lastHeard = Date()
            receive()
            pinger = Timer.scheduledTimer(withTimeInterval: CompanionService.pingInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.heartbeat() }
            }
            onReady?()
        case .failed(let error):
            close(error)
        case .waiting(let error):
            // TLS failures (wrong key) surface as "waiting" on the client; don't retry forever on one connection.
            close(error)
        case .cancelled:
            close(nil)
        default:
            break
        }
    }

    private func heartbeat() {
        if Date().timeIntervalSince(lastHeard) > CompanionService.timeout {
            close(URLError(.timedOut))
        } else {
            send(.ping)
        }
    }

    func send(_ message: CompanionMessage) {
        guard !closed, let frame = try? CompanionFraming.encode(message) else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.lastHeard = Date()
                    do {
                        for message in try self.decoder.append(data) where message != .ping {
                            self.onMessage?(message)
                        }
                    } catch {
                        self.close(error)
                        return
                    }
                }
                if complete || error != nil { self.close(error) } else { self.receive() }
            }
        }
    }

    func close(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        pinger?.invalidate()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(error)
        onClose = nil
    }
}

/// The link key and stable ids, in the Keychain / UserDefaults.
enum CompanionIdentity {
    private static let keyAccount = "companion.linkKey"

    static func storedKey(_ account: String = keyAccount) -> Data? {
        Keychain.get(account).flatMap { Data(base64Encoded: $0) }
    }

    static func store(key: Data?, _ account: String = keyAccount) {
        Keychain.set(key?.base64EncodedString(), for: account)
    }

    /// A random id that identifies this device to the other side, created once.
    static func deviceID(_ defaultsKey: String) -> String {
        if let id = UserDefaults.standard.string(forKey: defaultsKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: defaultsKey)
        return id
    }
}
