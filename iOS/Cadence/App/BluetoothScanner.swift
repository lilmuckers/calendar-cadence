import CadenceCore
import CoreBluetooth
import Foundation

/// The phone's Bluetooth LE end of the Mac link, shared by every `MacLink`: the last resort when
/// the network can't reach a Mac (docs/plans/bluetooth-fallback.md).
///
/// It scans only while some link wants Bluetooth (`TransportPlanner.wantsBluetooth`). For each
/// Cadence Mac it finds, it connects, reads the Mac tag to see which paired Mac it is (if any),
/// reads the L2CAP PSM and opens the channel, then hands it to that Mac's link.
@MainActor
final class BluetoothScanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// Bluetooth turned on/off, or the permission was answered: links re-check whether they can use it.
    var onStateChanged: (() -> Void)?

    private var manager: CBCentralManager?
    /// Links that want a channel, by Mac id: called with the channel once one is open.
    private var wanted: [String: (CBL2CAPChannel) -> Void] = [:]
    /// Peripherals being connected to and inspected.
    private var pending: [UUID: CBPeripheral] = [:]
    /// Which Mac each inspected peripheral turned out to be.
    private var macFor: [UUID: String] = [:]
    /// Peripherals whose channel a link is using, by Mac id (kept so the connection stays up).
    private var claimed: [String: CBPeripheral] = [:]
    /// Peripherals that weren't a Mac we want (another Cadence Mac nearby), or failed: left alone for a while.
    private var ignored: [UUID: Date] = [:]
    private static let ignoreFor: TimeInterval = 60

    /// Whether iOS lets Cadence use Bluetooth. `.notDetermined` = `activate()` asks.
    static var authorization: CBManagerAuthorization { CBManager.authorization }

    /// Bluetooth is on and Cadence may use it.
    var isUsable: Bool { manager?.state == .poweredOn }
    /// `activate()` has run (so iOS has been asked, or is asking).
    var isActivated: Bool { manager != nil }

    /// Creates the manager, which shows the Bluetooth prompt if iOS hasn't asked yet. Called at the
    /// end of pairing, or at launch once access was granted.
    func activate() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    /// `macID`'s link wants a Bluetooth channel; `deliver` gets it once open.
    func want(_ macID: String, deliver: @escaping (CBL2CAPChannel) -> Void) {
        wanted[macID] = deliver
        updateScan()
    }

    func unwant(_ macID: String) {
        guard wanted.removeValue(forKey: macID) != nil else { return }
        // Drop any inspection on this Mac's behalf that hasn't got as far as a channel.
        for (id, mac) in macFor where mac == macID {
            if let peripheral = pending[id] { manager?.cancelPeripheralConnection(peripheral) }
        }
        updateScan()
    }

    /// The link is done with its channel: let the Bluetooth connection go.
    func release(_ macID: String) {
        guard let peripheral = claimed.removeValue(forKey: macID) else { return }
        manager?.cancelPeripheralConnection(peripheral)
    }

    private func updateScan() {
        guard let manager, manager.state == .poweredOn else { return }
        if wanted.isEmpty {
            if manager.isScanning { manager.stopScan() }
        } else if !manager.isScanning {
            manager.scanForPeripherals(withServices: [CBUUID(string: BluetoothService.serviceUUID)])
        }
    }

    private func drop(_ peripheral: CBPeripheral, ignore: Bool) {
        if ignore { ignored[peripheral.identifier] = Date() }
        pending[peripheral.identifier] = nil
        macFor[peripheral.identifier] = nil
        manager?.cancelPeripheralConnection(peripheral)
    }

    // MARK: CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state != .poweredOn {
                pending = [:]
                macFor = [:]
                claimed = [:]
            }
            updateScan()
            onStateChanged?()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            guard !wanted.isEmpty, pending[id] == nil, !claimed.values.contains(where: { $0.identifier == id }) else { return }
            if let since = ignored[id], Date().timeIntervalSince(since) < Self.ignoreFor { return }
            ignored[id] = nil
            pending[id] = peripheral
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard pending[peripheral.identifier] != nil else { return }
            peripheral.delegate = self
            peripheral.discoverServices([CBUUID(string: BluetoothService.serviceUUID)])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { drop(peripheral, ignore: true) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            pending[peripheral.identifier] = nil
            macFor[peripheral.identifier] = nil
            // A channel in use ends with its streams; the link then releases it and may ask again.
            for (mac, claimed) in claimed where claimed.identifier == peripheral.identifier { self.claimed[mac] = nil }
            updateScan()
        }
    }

    // MARK: CBPeripheralDelegate

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: BluetoothService.serviceUUID) }) else {
                return drop(peripheral, ignore: true)
            }
            peripheral.discoverCharacteristics([CBUUID(string: BluetoothService.tagCharacteristicUUID),
                                                CBUUID(string: BluetoothService.psmCharacteristicUUID)], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, let tag = characteristic(BluetoothService.tagCharacteristicUUID, of: peripheral) else {
                return drop(peripheral, ignore: true)
            }
            // Which Mac is this? The tag first; the PSM only once we know it's one we want.
            peripheral.readValue(for: tag)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, let value = characteristic.value else { return drop(peripheral, ignore: true) }
            switch characteristic.uuid {
            case CBUUID(string: BluetoothService.tagCharacteristicUUID):
                let now = Date()
                guard let macID = wanted.keys.first(where: { claimed[$0] == nil && BluetoothMacTag.matches(value, macID: $0, at: now) }),
                      let psm = self.characteristic(BluetoothService.psmCharacteristicUUID, of: peripheral) else {
                    // Another Cadence Mac nearby, or ours but nobody wants it right now.
                    return drop(peripheral, ignore: true)
                }
                macFor[peripheral.identifier] = macID
                peripheral.readValue(for: psm)
            case CBUUID(string: BluetoothService.psmCharacteristicUUID):
                guard value.count == 2, macFor[peripheral.identifier] != nil else { return drop(peripheral, ignore: true) }
                let psm = CBL2CAPPSM(UInt16(value[value.startIndex]) << 8 | UInt16(value[value.startIndex + 1]))
                peripheral.openL2CAPChannel(psm)
            default:
                break
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            guard let channel, error == nil, let macID = macFor[id], let deliver = wanted[macID] else {
                return drop(peripheral, ignore: error != nil)
            }
            pending[id] = nil
            macFor[id] = nil
            claimed[macID] = peripheral
            // It has its channel; it asks again if that one goes.
            wanted[macID] = nil
            updateScan()
            deliver(channel)
        }
    }

    private func characteristic(_ uuid: String, of peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?.first { $0.uuid == CBUUID(string: BluetoothService.serviceUUID) }?
            .characteristics?.first { $0.uuid == CBUUID(string: uuid) }
    }
}
