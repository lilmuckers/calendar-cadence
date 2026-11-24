import CadenceCore
import Foundation
import Testing

struct LinkTrafficTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_040) // 20 s into a minute

    @Test func countsTotalsAndKinds() {
        var traffic = LinkTraffic()
        traffic.record(.ping, .sent, bytes: 20, at: t0)
        traffic.record(.ping, .received, bytes: 20, at: t0)
        traffic.record(.bye(reason: "x"), .received, bytes: 40, at: t0)
        #expect(traffic.totalBytes == 80)
        #expect(traffic.bytesSent == 20 && traffic.bytesReceived == 60)
        #expect(traffic.messagesSent == 1 && traffic.messagesReceived == 2)
        let ping = traffic.kinds["Ping"]
        #expect(ping?.sent == 1 && ping?.received == 1 && ping?.bytes == 40)
        #expect(traffic.buckets.count == 1)
        #expect(traffic.buckets[0].counts == ["Ping": 2, "Bye": 1])
        #expect(traffic.since == t0)
    }

    @Test func bucketsByMinuteAndFillsGaps() {
        var traffic = LinkTraffic()
        traffic.record(kind: "Snapshot", .received, bytes: 1000, at: t0)
        traffic.record(kind: "Snapshot", .received, bytes: 1000, at: t0.addingTimeInterval(45)) // next minute
        traffic.record(kind: "Media", .received, bytes: 10, at: t0.addingTimeInterval(200))
        #expect(traffic.buckets.count == 3)

        let timeline = traffic.timeline(window: 5 * 60, now: t0.addingTimeInterval(200))
        #expect(timeline.count == 6)
        #expect(timeline.map { $0.counts["Snapshot"] ?? 0 } == [0, 0, 1, 1, 0, 0])
        #expect(timeline.last?.counts["Media"] == 1)
        #expect(LinkTraffic.kinds(in: timeline) == ["Snapshot", "Media"])
        #expect(LinkTraffic.kinds(in: timeline, excluding: ["Snapshot"]) == ["Media"])
    }

    @Test func keepsOnlyRecentBucketsAndEntries() {
        var traffic = LinkTraffic()
        for i in 0..<(LinkTraffic.maxBuckets + 5) {
            traffic.record(.ping, .sent, bytes: 1, at: t0.addingTimeInterval(Double(i) * 60))
        }
        #expect(traffic.buckets.count == LinkTraffic.maxBuckets)
        #expect(traffic.recent.count == LinkTraffic.maxRecent)
        #expect(traffic.totalMessages == LinkTraffic.maxBuckets + 5)
    }

    @Test func decoderReportsFrameSizes() throws {
        let message = CompanionMessage.bye(reason: "done")
        let frame = try CompanionFraming.encode(message)
        var decoder = CompanionFrameDecoder()
        let out = try decoder.appendFrames(frame + frame)
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.message == message && $0.bytes == frame.count })
    }
}

@Suite("Link traffic transport")
struct LinkTrafficTransportTests {
    @Test func bluetoothShareIsCountedSeparately() {
        var traffic = LinkTraffic()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        traffic.record(.ping, .sent, bytes: 20, at: t0)
        traffic.record(.join(meetingID: "m"), .sent, bytes: 40, at: t0, over: .bluetooth)
        traffic.record(.ping, .received, bytes: 20, at: t0, over: .bluetooth)
        #expect(traffic.totalBytes == 80)
        #expect(traffic.bluetoothBytes == 60)
        #expect(traffic.bluetoothMessages == 2)
        #expect(traffic.recent.map(\.transport) == [.network, .bluetooth, .bluetooth])
    }
}
