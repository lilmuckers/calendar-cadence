import CadenceCore
import CoreBluetooth
import Foundation

/// The Bluetooth transport: one L2CAP channel's streams, encrypted with `BluetoothHandshake` and
/// `BluetoothSession` (TLS can't run over CoreBluetooth streams). The last resort, when the network
/// can't reach the Mac; see docs/plans/bluetooth-fallback.md.
///
/// The phone speaks first (its hello), the Mac answers if it holds that key, then both sides seal
/// every record. `onReady` fires once the handshake is done.
@MainActor
final class BluetoothTransport: NSObject, CompanionTransport, StreamDelegate {
    enum Role {
        /// The phone, offering `identity`'s key.
        case phone(key: Data, identity: String)
        /// The Mac: `key` looks up the key for the identity a phone offers (nil = not ours).
        case mac(key: (String) -> Data?)
    }

    let kind = CompanionTransportKind.bluetooth
    var onReady: (() -> Void)?
    var onReceive: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    /// The key identity the phone offered, once the Mac has accepted it.
    private(set) var identity: String?

    /// Held for as long as the transport lives: CoreBluetooth closes the channel when it's released.
    private let channel: CBL2CAPChannel
    private let role: Role
    private var client: BluetoothHandshake.Client?
    private var handshakeReader = BluetoothRecordReader()
    private var session: BluetoothSession?
    /// Bytes waiting for room in the output stream.
    private var outgoing = Data()
    private var closed = false

    init(channel: CBL2CAPChannel, role: Role) {
        self.channel = channel
        self.role = role
    }

    func start() {
        guard let input = channel.inputStream, let output = channel.outputStream else {
            finish(BluetoothLinkError.badHandshake)
            return
        }
        for stream in [input, output] as [Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        if case .phone(let key, let identity) = role {
            let client = BluetoothHandshake.Client(key: key, identity: identity)
            self.client = client
            write(BluetoothRecordReader.frame(client.hello))
        }
    }

    func send(_ data: Data) {
        guard !closed, session != nil else { return }
        do {
            write(try session!.seal(data))
        } catch {
            finish(error)
        }
    }

    func sessionBinding() -> Data? { session?.binding }

    func close() {
        guard !closed else { return }
        closed = true
        for stream in [channel.inputStream, channel.outputStream].compactMap({ $0 }) as [Stream] {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .main, forMode: .default)
        }
        outgoing = Data()
    }

    // MARK: Streams

    nonisolated func stream(_ stream: Stream, handle event: Stream.Event) {
        MainActor.assumeIsolated {
            guard !closed else { return }
            switch event {
            case .hasBytesAvailable: read()
            case .hasSpaceAvailable: flush()
            case .errorOccurred: finish(stream.streamError)
            case .endEncountered: finish(nil)
            default: break
            }
        }
    }

    private func read() {
        guard let input = channel.inputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var data = Data()
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        if !data.isEmpty { received(data) }
    }

    private func received(_ data: Data) {
        do {
            guard session != nil else { return try handshake(data) }
            let plaintext = try session!.open(data)
            for chunk in plaintext {
                onReceive?(chunk)
                // The channel may have closed us while handling that.
                if closed { return }
            }
        } catch {
            finish(error)
        }
    }

    /// The first record each way is the handshake; whatever follows it is already sealed.
    private func handshake(_ data: Data) throws {
        var records = try handshakeReader.append(data)
        guard !records.isEmpty else { return }
        let first = records.removeFirst()
        switch role {
        case .phone:
            guard let client else { throw BluetoothLinkError.badHandshake }
            session = try client.finish(first)
            identity = client.identity
        case .mac(let key):
            let (reply, session, identity) = try BluetoothHandshake.respond(to: first, key: key)
            write(BluetoothRecordReader.frame(reply))
            self.session = session
            self.identity = identity
        }
        client = nil
        onReady?()
        guard !closed else { return }
        // Records that arrived with the handshake, and the start of the next one.
        let rest = records.reduce(Data()) { $0 + BluetoothRecordReader.frame($1) } + handshakeReader.takeRemainder()
        if !rest.isEmpty { received(rest) }
    }

    private func write(_ data: Data) {
        outgoing.append(data)
        flush()
    }

    private func flush() {
        guard let output = channel.outputStream, !outgoing.isEmpty else { return }
        while !outgoing.isEmpty, output.hasSpaceAvailable {
            let written = outgoing.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: outgoing.count) }
            if written < 0 { return finish(output.streamError) }
            if written == 0 { break }
            outgoing.removeFirst(written)
        }
    }

    /// The link ended by itself: close, then tell the channel.
    private func finish(_ error: Error?) {
        guard !closed else { return }
        close()
        onClose?(error)
        onClose = nil
    }
}
