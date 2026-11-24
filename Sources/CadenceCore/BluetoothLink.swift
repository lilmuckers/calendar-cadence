import CryptoKit
import Foundation

/// How a channel's bytes travel between the Mac and a phone.
public enum CompanionTransportKind: String, Codable, Sendable {
    /// TCP + TLS-PSK over Wi-Fi, Ethernet or peer-to-peer Wi-Fi.
    case network
    /// An L2CAP channel over Bluetooth LE, encrypted with `BluetoothSession`. The last resort, when
    /// the network can't reach the Mac (`TransportPlanner`).
    case bluetooth
}

/// Bluetooth LE details both sides agree on (see docs/plans/bluetooth-fallback.md).
public enum BluetoothService {
    /// The GATT service the Mac advertises.
    public static let serviceUUID = "7C3A1E52-4B8D-4F0A-9E61-2D5C8B0F7A13"
    /// Readable: the L2CAP PSM to open, as a 2-byte big-endian number.
    public static let psmCharacteristicUUID = "7C3A1E52-4B8D-4F0A-9E61-2D5C8B0F7A14"
    /// Readable: this hour's `BluetoothMacTag`, so a phone picks out its own Mac.
    public static let tagCharacteristicUUID = "7C3A1E52-4B8D-4F0A-9E61-2D5C8B0F7A15"
}

public enum BluetoothLinkError: Error, Equatable {
    /// A record or handshake message claimed to be bigger than allowed.
    case recordTooLarge(Int)
    /// A handshake message wasn't one we understand (wrong version, wrong shape).
    case badHandshake
    /// The Mac holds no key for the identity the phone offered.
    case unknownKey
    /// A sealed record didn't open: wrong key, tampered, replayed or out of order.
    case badRecord
}

/// Splits a byte stream (in any chunking) into length-prefixed records: a 4-byte big-endian length,
/// then that many bytes. Carries the handshake messages and then the sealed records.
public struct BluetoothRecordReader: Sendable {
    /// Big enough for the largest `CompanionFraming` frame once sealed.
    public static let maxRecord = CompanionFraming.maxFrame + 4 + 16

    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var out: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Self.maxRecord else { throw BluetoothLinkError.recordTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            out.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return out
    }

    /// The bytes after the last complete record (the start of one still arriving), emptying the
    /// buffer: for handing the rest of the stream on to a `BluetoothSession` after the handshake.
    public mutating func takeRemainder() -> Data {
        defer { buffer = Data() }
        return buffer
    }

    public static func frame(_ body: Data) -> Data {
        var length = UInt32(body.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(body)
        return out
    }
}

/// The pre-shared-key handshake for the Bluetooth link: TLS can't run over a CoreBluetooth stream,
/// so this gives the same protection as the network link's `TLS_PSK_WITH_AES_128_GCM_SHA256`.
///
/// 1. Phone → Mac: version, the key's identity (as in TLS: `CompanionKeys.identity(for:)`), and a
///    32-byte random nonce.
/// 2. Mac → phone: version and a 32-byte random nonce, only if it holds that identity's key.
/// 3. Both derive, with HKDF-SHA256 over the link key (salt: both nonces), a key for each direction
///    and a 32-byte session binding that the hello proof signs, as the TLS exporter does on the network.
///
/// Each message travels as one `BluetoothRecordReader` record.
public enum BluetoothHandshake {
    public static let version: UInt8 = 1
    public static let nonceLength = 32
    static let info = Data("cadence-ble-v1".utf8)

    public static func newNonce() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<nonceLength).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    /// The phone's end: say which key, then finish with the Mac's reply.
    public struct Client: Sendable {
        public let identity: String
        private let key: Data
        private let nonce: Data

        public init(key: Data, identity: String, nonce: Data = BluetoothHandshake.newNonce()) {
            // Identities are "cadence" or "cadence.<16-char key id>"; the hello gives them one length byte.
            precondition(!identity.isEmpty && identity.utf8.count <= 255, "bad key identity")
            self.key = key
            self.identity = identity
            self.nonce = nonce
        }

        /// The first message, to send as one record.
        public var hello: Data {
            let id = Data(identity.utf8)
            var out = Data([BluetoothHandshake.version, UInt8(id.count)])
            out.append(id)
            out.append(nonce)
            return out
        }

        /// The Mac's reply (one record) → the session.
        public func finish(_ reply: Data) throws -> BluetoothSession {
            guard reply.count == 1 + nonceLength, reply.first == BluetoothHandshake.version else {
                throw BluetoothLinkError.badHandshake
            }
            let macNonce = Data(reply.dropFirst())
            return BluetoothSession(key: key, phoneNonce: nonce, macNonce: macNonce, role: .phone)
        }
    }

    /// The Mac's end: read the phone's hello, look up the key for the identity it names, reply.
    /// `key` returns nil for an identity the Mac doesn't hold (the link then closes).
    public static func respond(to hello: Data, nonce: Data = newNonce(),
                               key: (String) -> Data?) throws -> (reply: Data, session: BluetoothSession, identity: String) {
        let bytes = [UInt8](hello)
        guard bytes.count >= 2, bytes[0] == version else { throw BluetoothLinkError.badHandshake }
        let idLength = Int(bytes[1])
        guard idLength > 0, bytes.count == 2 + idLength + nonceLength,
              let identity = String(bytes: bytes[2..<(2 + idLength)], encoding: .utf8) else {
            throw BluetoothLinkError.badHandshake
        }
        guard let linkKey = key(identity) else { throw BluetoothLinkError.unknownKey }
        let phoneNonce = Data(bytes[(2 + idLength)...])
        var reply = Data([version])
        reply.append(nonce)
        return (reply, BluetoothSession(key: linkKey, phoneNonce: phoneNonce, macNonce: nonce, role: .mac), identity)
    }
}

/// One Bluetooth link's encryption, after `BluetoothHandshake`. Each record is ChaChaPoly-sealed
/// with its direction's key and a nonce counting up from 0, so a replayed, reordered or tampered
/// record fails to open.
public struct BluetoothSession: Sendable {
    public enum Role: Sendable { case phone, mac }

    /// Same bytes on both ends: what the hello proof signs (`CompanionKeys.proof`).
    public let binding: Data
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var reader = BluetoothRecordReader()

    init(key: Data, phoneNonce: Data, macNonce: Data, role: Role) {
        let material = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key), salt: phoneNonce + macNonce,
            info: BluetoothHandshake.info, outputByteCount: 96)
        let bytes = material.withUnsafeBytes { Data($0) }
        let phoneToMac = SymmetricKey(data: bytes[0..<32])
        let macToPhone = SymmetricKey(data: bytes[32..<64])
        binding = Data(bytes[64..<96])
        sendKey = role == .phone ? phoneToMac : macToPhone
        receiveKey = role == .phone ? macToPhone : phoneToMac
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var be = counter.bigEndian
        var data = Data(count: 4)
        data.append(Data(bytes: &be, count: 8))
        return try! ChaChaPoly.Nonce(data: data)
    }

    /// Seals `plaintext` into one record, ready to write to the stream.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sent))
        sent += 1
        return BluetoothRecordReader.frame(box.ciphertext + box.tag)
    }

    /// Appends bytes from the stream; returns the plaintext of every record now complete.
    public mutating func open(_ data: Data) throws -> [Data] {
        var out: [Data] = []
        for record in try reader.append(data) {
            guard record.count >= 16 else { throw BluetoothLinkError.badRecord }
            do {
                let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(received), ciphertext: record.dropLast(16), tag: record.suffix(16))
                out.append(try ChaChaPoly.open(box, using: receiveKey))
            } catch {
                throw BluetoothLinkError.badRecord
            }
            received += 1
        }
        return out
    }
}

/// What the Mac's Bluetooth service shows so a phone can tell its own Mac from others nearby,
/// without a fixed id anyone could track: 8 bytes of HMAC over the hour, keyed by the Mac's id.
/// Anyone who knows the Mac's id (its paired phones, and anyone seeing its Bonjour TXT record on
/// the same network) can work it out; nobody else can link one hour's tag to the next.
public enum BluetoothMacTag {
    public static let length = 8
    public static let period: TimeInterval = 60 * 60

    public static func tag(macID: String, at date: Date) -> Data {
        tag(macID: macID, hour: hour(date))
    }

    /// Whether `tag` is `macID`'s for the hour around `date`, allowing an hour either way for clocks
    /// that disagree and tags read just as the hour turns.
    public static func matches(_ tag: Data, macID: String, at date: Date) -> Bool {
        let now = hour(date)
        return [now - 1, now, now + 1].contains { Self.tag(macID: macID, hour: $0) == tag }
    }

    /// When the tag next changes, for the Mac to refresh it.
    public static func nextChange(after date: Date) -> Date {
        Date(timeIntervalSince1970: Double(hour(date) + 1) * period)
    }

    static func hour(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / period).rounded(.down))
    }

    static func tag(macID: String, hour: Int64) -> Data {
        let key = SymmetricKey(data: SHA256.hash(data: Data(macID.utf8)))
        var be = hour.bigEndian
        let message = Data("cadence-ble-tag".utf8) + Data(bytes: &be, count: 8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key).prefix(length))
    }
}
