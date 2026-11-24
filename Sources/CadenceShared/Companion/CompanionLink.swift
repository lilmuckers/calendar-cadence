import CadenceCore
import Foundation
import Network
import Security

/// Network parameters shared by the Mac's listener and the phone's connection: TCP + TLS 1.2 with
/// pre-shared keys (32-byte link keys from pairing), peer-to-peer allowed so the link also works
/// over AWDL when the two aren't on the same Wi-Fi.
enum CompanionNetwork {
    /// One key, for a phone dialling its Mac (`keyID` nil = the legacy shared key).
    static func parameters(key: Data, keyID: String?) -> NWParameters {
        parameters(keys: [(CompanionKeys.identity(for: keyID), key)])
    }

    /// Every phone's key, for the Mac's listener: TLS uses the one whose identity the phone offers.
    static func parameters(keys: [(identity: String, key: Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        for (identity, key) in keys {
            let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let id = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, id as __DispatchData)
        }
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

/// One framed connection between the Mac and a phone, over any `CompanionTransport` (which does
/// the encryption). Pings while open and closes itself after `CompanionService.timeout` of silence.
/// Everything runs on the main queue.
@MainActor
final class CompanionChannel {
    let transport: CompanionTransport
    var onMessage: ((CompanionMessage) -> Void)?
    var onReady: (() -> Void)?
    /// Called once, when the channel is gone for good.
    var onClose: ((Error?) -> Void)?
    /// Every message each way, pings included, with its size on the wire: for `LinkTraffic`.
    var onTraffic: ((CompanionMessage, LinkDirection, Int) -> Void)?

    private var decoder = CompanionFrameDecoder()
    /// When anything (pings included) last arrived.
    private(set) var lastHeard = Date()
    private var pinger: Timer?
    private var closed = false

    init(transport: CompanionTransport) {
        self.transport = transport
    }

    func start() {
        transport.onReady = { [weak self] in self?.ready() }
        transport.onReceive = { [weak self] data in self?.received(data) }
        transport.onClose = { [weak self] error in self?.close(error) }
        transport.start()
    }

    private func ready() {
        lastHeard = Date()
        pinger = Timer.scheduledTimer(withTimeInterval: CompanionService.pingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
        onReady?()
    }

    private func heartbeat() {
        if Date().timeIntervalSince(lastHeard) > CompanionService.timeout {
            close(URLError(.timedOut))
        } else {
            send(.ping)
        }
    }

    /// Keying material unique to this encrypted session, which the hello proof signs. Nil before
    /// the session is up.
    func sessionBinding() -> Data? { transport.sessionBinding() }

    func send(_ message: CompanionMessage) {
        guard !closed, let frame = try? CompanionFraming.encode(message) else { return }
        transport.send(frame)
        onTraffic?(message, .sent, frame.count)
    }

    private func received(_ data: Data) {
        guard !closed else { return }
        lastHeard = Date()
        do {
            for (message, bytes) in try decoder.appendFrames(data) {
                onTraffic?(message, .received, bytes)
                if message != .ping { onMessage?(message) }
            }
        } catch {
            close(error)
        }
    }

    func close(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        pinger?.invalidate()
        transport.onClose = nil
        transport.close()
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
