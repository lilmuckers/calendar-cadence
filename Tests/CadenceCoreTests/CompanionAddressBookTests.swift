import Foundation
import Testing
@testable import CadenceCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 24 * 60 * 60

@Suite("Companion address book")
struct CompanionAddressBookTests {
    @Test func secondNetworkIsKeptAlongsideTheFirst() {
        var book = CompanionAddressBook()
        book.learn(hosts: ["192.168.0.21"], port: 62166, now: t0, worked: false)
        book.learn(hosts: ["10.4.2.9"], port: 62166, now: t0.addingTimeInterval(3600), worked: false)
        #expect(book.entries.count == 2)
        // Neither has worked yet: newest first.
        #expect(book.dialOrder.map(\.host) == ["10.4.2.9", "192.168.0.21"])
    }

    @Test func sameNetworkIsNotDuplicated() {
        var book = CompanionAddressBook()
        book.learn(hosts: ["192.168.0.21", "192.168.0.30"], port: 62166, now: t0, worked: false)
        book.learn(hosts: ["192.168.0.30", "192.168.0.21"], port: 62166, now: t0.addingTimeInterval(60), worked: true)
        #expect(book.entries.count == 1)
        #expect(book.entries[0].lastWorked == t0.addingTimeInterval(60))
    }

    @Test func workingNetworkIsDialledFirst() {
        var book = CompanionAddressBook()
        book.learn(hosts: ["192.168.0.21"], port: 62166, now: t0, worked: false)
        book.learn(hosts: ["10.4.2.9"], port: 62166, now: t0, worked: false)
        book.markWorked(host: "192.168.0.21", port: 62166, now: t0.addingTimeInterval(10))
        #expect(book.dialOrder.map(\.host) == ["192.168.0.21", "10.4.2.9"])
        book.markWorked(host: "10.4.2.9", port: 62166, now: t0.addingTimeInterval(20))
        #expect(book.dialOrder.map(\.host) == ["10.4.2.9", "192.168.0.21"])
    }

    @Test func setUnusedForAWeekExpires() {
        var book = CompanionAddressBook()
        book.learn(hosts: ["192.168.0.21"], port: 62166, now: t0, worked: true)
        book.learn(hosts: ["10.4.2.9"], port: 62166, now: t0, worked: true)
        book.markWorked(host: "10.4.2.9", port: 62166, now: t0.addingTimeInterval(6 * day))
        book.prune(now: t0.addingTimeInterval(7 * day - 1))
        #expect(book.entries.count == 2)
        book.prune(now: t0.addingTimeInterval(7 * day + 1))
        #expect(book.entries.map(\.hosts) == [["10.4.2.9"]])
    }

    @Test func neverWorkingSetExpiresAWeekAfterItWasLearnt() {
        var book = CompanionAddressBook()
        book.learn(hosts: ["192.168.0.21"], port: 62166, now: t0, worked: true)
        book.learn(hosts: ["10.4.2.9"], port: 62166, now: t0.addingTimeInterval(day), worked: false)
        book.markWorked(host: "192.168.0.21", port: 62166, now: t0.addingTimeInterval(8 * day))
        book.prune(now: t0.addingTimeInterval(8 * day + 1))
        #expect(book.entries.map(\.hosts) == [["192.168.0.21"]])
    }

    @Test func mostRecentSetIsKeptEvenWhenStale() {
        var book = CompanionAddressBook()
        book.learn(hosts: ["192.168.0.21"], port: 62166, now: t0, worked: true)
        book.learn(hosts: ["10.4.2.9"], port: 62166, now: t0.addingTimeInterval(day), worked: true)
        book.prune(now: t0.addingTimeInterval(30 * day))
        #expect(book.entries.map(\.hosts) == [["10.4.2.9"]])
    }

    @Test func emptyOrPortlessSetsAreIgnored() {
        var book = CompanionAddressBook()
        book.learn(hosts: [], port: 62166, now: t0, worked: true)
        book.learn(hosts: ["192.168.0.21"], port: nil, now: t0, worked: true)
        book.learn(hosts: ["192.168.0.21"], port: 0, now: t0, worked: true)
        #expect(book.entries.isEmpty)
        #expect(book.dialOrder.isEmpty)
    }

    @Test func sharedHostIsDialledOnce() {
        var book = CompanionAddressBook()
        book.learn(hosts: ["192.168.0.21", "192.168.0.30"], port: 62166, now: t0, worked: true)
        book.learn(hosts: ["192.168.0.21"], port: 62166, now: t0.addingTimeInterval(60), worked: true)
        #expect(book.dialOrder.map(\.host) == ["192.168.0.21", "192.168.0.30"])
    }

    @Test func roundTrips() throws {
        var book = CompanionAddressBook()
        book.learn(hosts: ["192.168.0.21"], port: 62166, now: t0, worked: true)
        let back = try JSONDecoder().decode(CompanionAddressBook.self, from: JSONEncoder().encode(book))
        #expect(back == book)
    }
}

@Suite("Companion device name")
struct CompanionDeviceNameTests {
    @Test func realNameWins() {
        #expect(CompanionDeviceName.label(name: "Pat's iPhone", model: "iPhone17,1") == "Pat's iPhone")
    }

    @Test func genericNameFallsBackToModel() {
        #expect(CompanionDeviceName.label(name: "iPhone", model: "iPhone17,1") == "iPhone 16 Pro")
        #expect(CompanionDeviceName.label(name: "", model: "iPhone18,4") == "iPhone Air")
    }

    @Test func unknownModelFallsBackToFamily() {
        #expect(CompanionDeviceName.label(name: "iPhone", model: "iPhone99,9") == "iPhone")
        #expect(CompanionDeviceName.label(name: "iPad", model: "iPad16,3") == "iPad")
    }

    @Test func olderPhoneWithoutModelKeepsItsName() {
        #expect(CompanionDeviceName.label(name: "iPhone", model: nil) == "iPhone")
    }

    @Test func helloWithoutModelStillDecodes() throws {
        let json = #"{"protocolVersion":1,"deviceID":"d","deviceName":"iPhone","displaying":true}"#
        let hello = try JSONDecoder().decode(CompanionHello.self, from: Data(json.utf8))
        #expect(hello.deviceModel == nil)
        #expect(hello.label == "iPhone")
    }
}
