import Foundation
import Testing
@testable import CadenceCore

private let key = Data(repeating: 0x42, count: 32)
private let otherKey = Data(repeating: 0x17, count: 32)
private let identity = CompanionKeys.identity(for: "abcdefghijklmnop")

/// Runs the handshake both ways and returns the phone's and the Mac's sessions.
private func handshake(phoneKey: Data = key, macKey: Data = key) throws -> (phone: BluetoothSession, mac: BluetoothSession) {
    let client = BluetoothHandshake.Client(key: phoneKey, identity: identity)
    let (reply, mac, seen) = try BluetoothHandshake.respond(to: client.hello) { $0 == identity ? macKey : nil }
    #expect(seen == identity)
    return (try client.finish(reply), mac)
}

@Suite("Bluetooth link")
struct BluetoothLinkTests {
    @Test func bothEndsAgreeOnTheBinding() throws {
        let (phone, mac) = try handshake()
        #expect(phone.binding == mac.binding)
        #expect(phone.binding.count == 32)
    }

    @Test func bindingIsFreshEachSession() throws {
        let first = try handshake()
        let second = try handshake()
        #expect(first.phone.binding != second.phone.binding)
    }

    @Test func helloProofWorksOverTheBinding() throws {
        let (phone, mac) = try handshake()
        let proof = CompanionKeys.proof(key: key, binding: phone.binding)
        #expect(CompanionKeys.verify(proof, key: key, binding: mac.binding))
    }

    @Test func recordsRoundTripBothWays() throws {
        var (phone, mac) = try handshake()
        let frames = [try CompanionFraming.encode(.ping), try CompanionFraming.encode(.join(meetingID: "m1"))]
        var wire = Data()
        for frame in frames { wire += try phone.seal(frame) }
        #expect(try mac.open(wire) == frames)

        let back = try CompanionFraming.encode(.welcome(macID: "M", macName: "Mac"))
        #expect(try phone.open(try mac.seal(back)) == [back])
    }

    @Test func recordsSurviveAnyChunking() throws {
        var (phone, mac) = try handshake()
        let messages = (0..<5).map { Data("message \($0)".utf8) }
        var wire = Data()
        for m in messages { wire += try phone.seal(m) }
        var out: [Data] = []
        // One byte at a time, as a slow stream might deliver it.
        for byte in wire { out += try mac.open(Data([byte])) }
        #expect(out == messages)
    }

    @Test func wrongKeyFailsToOpen() throws {
        var (phone, mac) = try handshake(phoneKey: key, macKey: otherKey)
        #expect(throws: BluetoothLinkError.badRecord) { try mac.open(try phone.seal(Data("hi".utf8))) }
    }

    @Test func unknownIdentityIsRefused() {
        let client = BluetoothHandshake.Client(key: key, identity: identity)
        #expect(throws: BluetoothLinkError.unknownKey) {
            try BluetoothHandshake.respond(to: client.hello) { _ in nil }
        }
    }

    @Test func malformedHandshakeIsRefused() throws {
        #expect(throws: BluetoothLinkError.badHandshake) {
            try BluetoothHandshake.respond(to: Data([9, 1, 0x61]) + BluetoothHandshake.newNonce()) { _ in key }
        }
        #expect(throws: BluetoothLinkError.badHandshake) {
            try BluetoothHandshake.respond(to: Data([BluetoothHandshake.version, 0]) + BluetoothHandshake.newNonce()) { _ in key }
        }
        let client = BluetoothHandshake.Client(key: key, identity: identity)
        #expect(throws: BluetoothLinkError.badHandshake) { try client.finish(Data([BluetoothHandshake.version, 1, 2])) }
    }

    @Test func replayedRecordFails() throws {
        var (phone, mac) = try handshake()
        let record = try phone.seal(Data("join".utf8))
        _ = try mac.open(record)
        #expect(throws: BluetoothLinkError.badRecord) { try mac.open(record) }
    }

    @Test func reorderedRecordsFail() throws {
        var (phone, mac) = try handshake()
        let first = try phone.seal(Data("one".utf8))
        let second = try phone.seal(Data("two".utf8))
        _ = first
        #expect(throws: BluetoothLinkError.badRecord) { try mac.open(second) }
    }

    @Test func tamperedRecordFails() throws {
        var (phone, mac) = try handshake()
        var record = try phone.seal(Data("snooze".utf8))
        record[record.count - 1] ^= 0x01
        #expect(throws: BluetoothLinkError.badRecord) { try mac.open(record) }
    }

    @Test func replayedSessionFailsOnTheMac() throws {
        // Someone records a whole session (the phone's hello and its records) and plays it back
        // later: the Mac answers with a new nonce, so the recorded records don't open.
        let client = BluetoothHandshake.Client(key: key, identity: identity)
        let (reply, _, _) = try BluetoothHandshake.respond(to: client.hello) { _ in key }
        var phone = try client.finish(reply)
        let recorded = try phone.seal(Data("join".utf8))
        var (_, replayed, _) = try BluetoothHandshake.respond(to: client.hello) { _ in key }
        #expect(throws: BluetoothLinkError.badRecord) { try replayed.open(recorded) }
    }

    @Test func ownRecordsDontOpenAsTheOtherDirection() throws {
        var (phone, _) = try handshake()
        var copy = phone
        // A record reflected back at its sender uses the other direction's key.
        #expect(throws: BluetoothLinkError.badRecord) { try copy.open(try phone.seal(Data("x".utf8))) }
    }

    @Test func sealedRecordsArrivingWithTheHandshakeAreKept() throws {
        // The Mac's reply and its first sealed records can arrive in one chunk; what's left after
        // the handshake record goes on to the session.
        let client = BluetoothHandshake.Client(key: key, identity: identity)
        var (reply, mac, _) = try BluetoothHandshake.respond(to: client.hello) { _ in key }
        let sealed = try mac.seal(Data("welcome".utf8)) + mac.seal(Data("snapshot".utf8))
        let wire = BluetoothRecordReader.frame(reply) + sealed

        var reader = BluetoothRecordReader()
        var records = try reader.append(wire.dropLast(3))
        var phone = try client.finish(records.removeFirst())
        let rest = records.reduce(Data()) { $0 + BluetoothRecordReader.frame($1) } + reader.takeRemainder()
        #expect(try phone.open(rest) + phone.open(wire.suffix(3)) == [Data("welcome".utf8), Data("snapshot".utf8)])
        #expect(reader.takeRemainder().isEmpty)
    }

    @Test func oversizedRecordIsRefused() throws {
        var reader = BluetoothRecordReader()
        var length = UInt32(BluetoothRecordReader.maxRecord + 1).bigEndian
        #expect(throws: BluetoothLinkError.self) { try reader.append(Data(bytes: &length, count: 4)) }
    }
}

@Suite("Bluetooth Mac tag")
struct BluetoothMacTagTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func tagIsStableWithinTheHour() {
        let hourStart = Date(timeIntervalSince1970: (t0.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        let tag = BluetoothMacTag.tag(macID: "MAC", at: hourStart)
        #expect(tag.count == BluetoothMacTag.length)
        #expect(BluetoothMacTag.tag(macID: "MAC", at: hourStart.addingTimeInterval(3599)) == tag)
        #expect(BluetoothMacTag.tag(macID: "MAC", at: hourStart.addingTimeInterval(3600)) != tag)
    }

    @Test func tagDiffersBetweenMacs() {
        #expect(BluetoothMacTag.tag(macID: "MAC-A", at: t0) != BluetoothMacTag.tag(macID: "MAC-B", at: t0))
    }

    @Test func matchAllowsAnHourOfSkew() {
        let tag = BluetoothMacTag.tag(macID: "MAC", at: t0)
        #expect(BluetoothMacTag.matches(tag, macID: "MAC", at: t0))
        #expect(BluetoothMacTag.matches(tag, macID: "MAC", at: t0.addingTimeInterval(3600)))
        #expect(BluetoothMacTag.matches(tag, macID: "MAC", at: t0.addingTimeInterval(-3600)))
        #expect(!BluetoothMacTag.matches(tag, macID: "MAC", at: t0.addingTimeInterval(3 * 3600)))
        #expect(!BluetoothMacTag.matches(tag, macID: "OTHER", at: t0))
    }

    @Test func nextChangeIsTheNextHour() {
        let next = BluetoothMacTag.nextChange(after: t0)
        #expect(next > t0)
        #expect(next.timeIntervalSince(t0) <= 3600)
        #expect(next.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) == 0)
    }
}
