import CadenceCore
import Foundation
import Network

/// An encrypted byte stream between the Mac and a phone, underneath a `CompanionChannel`. The
/// channel does the framing, pings and timeout; the transport only moves bytes and says when it's
/// ready or gone. Everything runs on the main queue.
@MainActor
protocol CompanionTransport: AnyObject {
    var kind: CompanionTransportKind { get }
    /// The encrypted session is up and bytes can flow.
    var onReady: (() -> Void)? { get set }
    /// Bytes arrived (any chunking: the channel's frame decoder reassembles them).
    var onReceive: ((Data) -> Void)? { get set }
    /// The transport ended by itself (failed, refused, or the other end closed). Not called after `close()`.
    var onClose: ((Error?) -> Void)? { get set }

    func start()
    func send(_ data: Data)
    /// Keying material unique to this encrypted session (both ends get the same bytes), which the
    /// hello proof signs. Nil before the session is up.
    func sessionBinding() -> Data?
    /// Ends the transport. Quiet: `onClose` isn't called for a close we asked for.
    func close()
}

/// The network transport: one `NWConnection` made with `CompanionNetwork.parameters`.
@MainActor
final class NetworkTransport: CompanionTransport {
    let connection: NWConnection
    let kind = CompanionTransportKind.network
    var onReady: (() -> Void)?
    var onReceive: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

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
            receive()
            onReady?()
        case .failed(let error):
            finish(error)
        case .waiting(let error):
            // TLS failures (wrong key) surface as "waiting" on the client; don't retry forever on one connection.
            finish(error)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.onReceive?(data) }
                // The channel may have closed us while handling those bytes.
                guard !self.closed else { return }
                if complete || error != nil { self.finish(error) } else { self.receive() }
            }
        }
    }

    func sessionBinding() -> Data? {
        guard let meta = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let secret = sec_protocol_metadata_create_secret(
                  meta.securityProtocolMetadata, CompanionKeys.exporterLabel.utf8.count,
                  CompanionKeys.exporterLabel, CompanionKeys.exporterLength) else { return nil }
        return Data(secret as DispatchData)
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// The connection ended by itself: close, then tell the channel.
    private func finish(_ error: Error?) {
        guard !closed else { return }
        close()
        onClose?(error)
        onClose = nil
    }
}
