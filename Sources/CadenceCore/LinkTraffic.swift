import Foundation

/// Which way a message went, from this device's point of view.
public enum LinkDirection: String, Codable, Sendable {
    case sent, received
}

extension CompanionMessage {
    /// A short, readable name for the kind of message, for the link analytics ("Snapshot", "Ping").
    public var kind: String {
        switch self {
        case .hello: "Hello"
        case .displayState: "Display state"
        case .join: "Join"
        case .snooze: "Snooze"
        case .dismiss: "Dismiss"
        case .rsvp: "RSVP"
        case .inviteLater: "Invite later"
        case .resolveClash: "Resolve clash"
        case .enrichmentAction: "Enrichment"
        case .joinMeeting: "Join meeting"
        case .welcome: "Welcome"
        case .address: "Address"
        case .features: "Features"
        case .rekey: "Rekey"
        case .snapshot: "Snapshot"
        case .alert: "Alert"
        case .dismissAlert: "Dismiss alert"
        case .reminder: "Reminder"
        case .invitePrompt: "Invite prompt"
        case .inviteHandled: "Invite handled"
        case .clashPrompt: "Clash prompt"
        case .clashHandled: "Clash handled"
        case .media: "Media"
        case .mediaCommand: "Media command"
        case .volume: "Volume"
        case .ping: "Ping"
        case .bye: "Bye"
        }
    }
}

/// What's gone over the link with one paired device: totals, one-minute buckets for the charts and
/// the last few messages. Kept in memory only, so it covers the time since the app opened.
public struct LinkTraffic: Equatable, Sendable {
    public static let bucketLength: TimeInterval = 60
    /// Three hours of minutes; older buckets drop off (the totals keep counting).
    public static let maxBuckets = 180
    public static let maxRecent = 50

    public struct Bucket: Equatable, Sendable {
        /// The start of the minute.
        public var start: Date
        public var bytesSent = 0
        public var bytesReceived = 0
        /// Messages of each kind, both directions together.
        public var counts: [String: Int] = [:]

        public var bytes: Int { bytesSent + bytesReceived }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: Int
        public var at: Date
        public var kind: String
        public var direction: LinkDirection
        public var bytes: Int
        /// What it travelled over.
        public var transport: CompanionTransportKind = .network
    }

    public struct KindTotal: Equatable, Sendable {
        public var sent = 0
        public var received = 0
        public var bytes = 0
        public var count: Int { sent + received }
    }

    public private(set) var buckets: [Bucket] = []
    public private(set) var recent: [Entry] = []
    public private(set) var kinds: [String: KindTotal] = [:]
    public private(set) var bytesSent = 0
    public private(set) var bytesReceived = 0
    public private(set) var messagesSent = 0
    public private(set) var messagesReceived = 0
    /// The part of the totals that went over Bluetooth (the last resort, when the network can't connect).
    public private(set) var bluetoothBytes = 0
    public private(set) var bluetoothMessages = 0
    /// When the first message was recorded.
    public private(set) var since: Date?
    public private(set) var lastActivity: Date?
    private var nextID = 0

    public init() {}

    public var totalBytes: Int { bytesSent + bytesReceived }
    public var totalMessages: Int { messagesSent + messagesReceived }
    public var isEmpty: Bool { totalMessages == 0 }

    public mutating func record(_ message: CompanionMessage, _ direction: LinkDirection, bytes: Int, at date: Date = Date(),
                                over transport: CompanionTransportKind = .network) {
        record(kind: message.kind, direction, bytes: bytes, at: date, over: transport)
    }

    public mutating func record(kind: String, _ direction: LinkDirection, bytes: Int, at date: Date = Date(),
                                over transport: CompanionTransportKind = .network) {
        if since == nil { since = date }
        lastActivity = max(lastActivity ?? date, date)

        let start = Self.bucketStart(date)
        if let i = buckets.lastIndex(where: { $0.start == start }) {
            add(kind, direction, bytes, to: &buckets[i])
        } else {
            var bucket = Bucket(start: start)
            add(kind, direction, bytes, to: &bucket)
            // Messages normally arrive in order; a late one still lands in its own minute.
            let at = buckets.firstIndex { $0.start > start } ?? buckets.endIndex
            buckets.insert(bucket, at: at)
            if buckets.count > Self.maxBuckets { buckets.removeFirst(buckets.count - Self.maxBuckets) }
        }

        switch direction {
        case .sent: bytesSent += bytes; messagesSent += 1
        case .received: bytesReceived += bytes; messagesReceived += 1
        }
        if transport == .bluetooth {
            bluetoothBytes += bytes
            bluetoothMessages += 1
        }
        var total = kinds[kind] ?? KindTotal()
        if direction == .sent { total.sent += 1 } else { total.received += 1 }
        total.bytes += bytes
        kinds[kind] = total

        recent.append(Entry(id: nextID, at: date, kind: kind, direction: direction, bytes: bytes, transport: transport))
        nextID += 1
        if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
    }

    private func add(_ kind: String, _ direction: LinkDirection, _ bytes: Int, to bucket: inout Bucket) {
        if direction == .sent { bucket.bytesSent += bytes } else { bucket.bytesReceived += bytes }
        bucket.counts[kind, default: 0] += 1
    }

    public static func bucketStart(_ date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / bucketLength).rounded(.down) * bucketLength)
    }

    /// Every minute from `window` before `now` up to `now`'s minute, with empty minutes filled in, so
    /// a chart drops to zero while the devices were apart instead of drawing a line across the gap.
    public func timeline(window: TimeInterval, now: Date = Date()) -> [Bucket] {
        let last = Self.bucketStart(now)
        let first = Self.bucketStart(now.addingTimeInterval(-window))
        let minutes = Int((last.timeIntervalSince(first) / Self.bucketLength).rounded()) + 1
        var byStart: [Date: Bucket] = [:]
        for bucket in buckets where bucket.start >= first && bucket.start <= last { byStart[bucket.start] = bucket }
        return (0..<minutes).map { i in
            let start = first.addingTimeInterval(Double(i) * Self.bucketLength)
            return byStart[start] ?? Bucket(start: start)
        }
    }

    /// Kinds with any messages in `buckets`, busiest first.
    public static func kinds(in buckets: [Bucket], excluding excluded: Set<String> = []) -> [String] {
        var totals: [String: Int] = [:]
        for bucket in buckets { for (kind, n) in bucket.counts where !excluded.contains(kind) { totals[kind, default: 0] += n } }
        return totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}
