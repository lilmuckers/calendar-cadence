import Foundation
import Network

/// Tells the app when the network comes back (after sleep, a Wi-Fi change, a VPN connecting), so
/// remote calendars are refetched straight away instead of waiting for the next 10-minute refresh.
@MainActor
final class NetworkWatcher {
    var onRestored: (() -> Void)?
    private let monitor = NWPathMonitor()
    private var satisfied: Bool?
    private var pending: DispatchWorkItem?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.changed(ok) }
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    private func changed(_ ok: Bool) {
        defer { satisfied = ok }
        guard ok, satisfied == false else {
            if !ok { pending?.cancel() }
            return
        }
        // Paths often flap while an interface comes up (DHCP, captive checks); wait for it to settle.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onRestored?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    deinit { monitor.cancel() }
}
