import CadenceCore
import Foundation
import Observation

/// Link analytics for every paired device, keyed by its id (a phone's device id on the Mac, a Mac's
/// id on the phone). In memory only: it covers the time since the app opened.
@MainActor
@Observable
final class LinkTrafficStore {
    private(set) var logs: [String: LinkTraffic] = [:]

    func traffic(for peer: String) -> LinkTraffic { logs[peer] ?? LinkTraffic() }

    func record(kind: String, _ direction: LinkDirection, bytes: Int, at date: Date = Date(), peer: String,
                over transport: CompanionTransportKind = .network) {
        logs[peer, default: LinkTraffic()].record(kind: kind, direction, bytes: bytes, at: date, over: transport)
    }

    func reset(_ peer: String) { logs[peer] = nil }
}
