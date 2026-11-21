import Foundation

/// What the Mac shows as a QR code (and a copyable link) to pair an iPhone.
///
/// The link carries the Mac's 256-bit link key itself, so there's no guessable short code: whoever can
/// see the Mac's screen can pair, nobody sniffing the network can. Both sides then use the key as a
/// TLS pre-shared key. Each code is a fresh key for one phone (`keyID`) and works once.
public struct PairingInvite: Equatable, Sendable {
    public static let scheme = "cadence-pair"
    public static let keyLength = 32

    public var macID: String
    public var macName: String
    public var key: Data
    /// Which key this is (`CompanionKeys`). Nil from older Macs, whose one key every phone shares.
    public var keyID: String?
    /// The Mac's LAN addresses and listening port, so the phone can dial it directly when Bonjour
    /// can't find it (networks or security software that drop multicast DNS). Optional: older invites
    /// don't carry them.
    public var hosts: [String]
    public var port: UInt16?

    public init(macID: String, macName: String, key: Data, keyID: String? = nil, hosts: [String] = [], port: UInt16? = nil) {
        self.macID = macID
        self.macName = macName
        self.key = key
        self.keyID = keyID
        self.hosts = hosts
        self.port = port
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        c.queryItems = [
            .init(name: "v", value: String(CompanionService.protocolVersion)),
            .init(name: "id", value: macID),
            .init(name: "name", value: macName),
            .init(name: "k", value: Self.base64URL(key)),
        ] + (keyID.map { [.init(name: "i", value: $0)] } ?? []) + hosts.map { .init(name: "h", value: $0) } + (port.map { [.init(name: "p", value: String($0))] } ?? [])
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let id = value("id"), !id.isEmpty,
              let k = value("k").flatMap(Self.data(base64URL:)), k.count == Self.keyLength else { return nil }
        self.init(macID: id, macName: value("name") ?? "Mac", key: k, keyID: value("i").flatMap { $0.isEmpty ? nil : $0 },
                  hosts: items.filter { $0.name == "h" }.compactMap(\.value).filter { !$0.isEmpty },
                  port: value("p").flatMap(UInt16.init).flatMap { $0 == 0 ? nil : $0 })
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    public static func newKey() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<keyLength).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
}
