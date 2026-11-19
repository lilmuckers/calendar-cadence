import Foundation

/// One set of addresses a Mac was reachable at (its LAN addresses on one network, plus its port).
public struct CompanionAddress: Codable, Equatable, Sendable {
    public var hosts: [String]
    public var port: UInt16
    /// When the phone first learnt this set (pairing code or the Mac telling it).
    public var added: Date
    /// When a connection over this set (or while the Mac was on it) last worked. Nil = never yet.
    public var lastWorked: Date?

    public init(hosts: [String], port: UInt16, added: Date, lastWorked: Date? = nil) {
        self.hosts = hosts
        self.port = port
        self.added = added
        self.lastWorked = lastWorked
    }

    /// The last time this set was any good: when it last worked, or when it was learnt.
    public var lastGood: Date { max(added, lastWorked ?? added) }

    func sameNetwork(as hosts: [String], port: UInt16) -> Bool {
        self.port == port && Set(self.hosts) == Set(hosts)
    }
}

/// Every address set a paired Mac has been seen at, so a phone that moves between networks (home,
/// office) keeps each one and dials them in turn until one answers. A set that hasn't worked for
/// `expiry` is dropped, except the most recent one, so the phone always has somewhere to try.
public struct CompanionAddressBook: Codable, Equatable, Sendable {
    public static let expiry: TimeInterval = 7 * 24 * 60 * 60

    public private(set) var entries: [CompanionAddress]

    public init(entries: [CompanionAddress] = []) {
        self.entries = entries
    }

    /// Add a set (from a pairing code, or the Mac telling a connected phone where it is now).
    /// A set already known for the same network is refreshed rather than duplicated.
    /// `worked`: it came over a live link, so it counts as working now.
    public mutating func learn(hosts: [String], port: UInt16?, now: Date, worked: Bool) {
        let hosts = Self.unique(hosts)
        guard let port, port != 0, !hosts.isEmpty else { return }
        if let i = entries.firstIndex(where: { $0.sameNetwork(as: hosts, port: port) }) {
            if worked { entries[i].lastWorked = now }
        } else {
            entries.append(CompanionAddress(hosts: hosts, port: port, added: now, lastWorked: worked ? now : nil))
        }
        prune(now: now)
    }

    /// A direct dial to `host:port` reached the Mac: every set holding it worked.
    public mutating func markWorked(host: String, port: UInt16, now: Date) {
        for i in entries.indices where entries[i].port == port && entries[i].hosts.contains(host) {
            entries[i].lastWorked = now
        }
    }

    /// Drop sets that haven't worked (or, never having worked, were learnt) more than `expiry` ago.
    /// The most recently good set always stays.
    public mutating func prune(now: Date) {
        guard let keep = ordered.first else { return }
        entries.removeAll { $0 != keep && now.timeIntervalSince($0.lastGood) > Self.expiry }
    }

    /// Sets, most recently working first; sets that never worked come after, newest first.
    public var ordered: [CompanionAddress] {
        entries.sorted { a, b in
            switch (a.lastWorked, b.lastWorked) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.added > b.added
            }
        }
    }

    /// Every host:port to dial, in the order to try them, without repeats.
    public var dialOrder: [(host: String, port: UInt16)] {
        var seen = Set<String>()
        var out: [(host: String, port: UInt16)] = []
        for entry in ordered {
            for host in entry.hosts where seen.insert("\(host):\(entry.port)").inserted {
                out.append((host, entry.port))
            }
        }
        return out
    }

    private static func unique(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
