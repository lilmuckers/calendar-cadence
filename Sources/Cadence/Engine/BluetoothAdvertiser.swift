import CadenceCore
import CoreBluetooth
import Foundation

/// The Mac's Bluetooth LE end of the iPhone link: the last resort when the network can't reach it
/// (docs/plans/bluetooth-fallback.md).
///
/// It advertises the Cadence service and publishes an L2CAP channel. The service has two readable
/// characteristics: the channel's PSM, and this hour's `BluetoothMacTag` so a phone can tell its Mac
/// from others nearby. Each channel a phone opens becomes a `BluetoothTransport` for the hub. A phone
/// only uses this when the network fails, so it's fine to advertise all the time.
@MainActor
final class BluetoothAdvertiser: NSObject, CBPeripheralManagerDelegate {
    /// A phone opened a channel: the hub runs it like a network connection.
    var onChannel: ((BluetoothTransport) -> Void)?
    /// Bluetooth's state changed (on/off, permission), for the settings.
    var onStateChanged: (() -> Void)?

    private let macID: String
    private let keys: () -> [(identity: String, key: Data)]
    private var manager: CBPeripheralManager?
    private var psm: CBL2CAPPSM?
    private var service: CBMutableService?
    private var running = false

    init(macID: String, keys: @escaping () -> [(identity: String, key: Data)]) {
        self.macID = macID
        self.keys = keys
    }

    /// Whether macOS lets Cadence use Bluetooth. `.notDetermined` = starting asks.
    static var authorization: CBManagerAuthorization { CBManager.authorization }

    var state: CBManagerState { manager?.state ?? .unknown }
    var isAdvertising: Bool { manager?.isAdvertising ?? false }

    /// Starts advertising (creating the manager the first time shows the Bluetooth prompt if macOS
    /// hasn't asked yet). Waits for Bluetooth to be on if it isn't.
    func start() {
        running = true
        if let manager {
            if manager.state == .poweredOn { publish() }
        } else {
            manager = CBPeripheralManager(delegate: self, queue: .main)
        }
    }

    func stop() {
        running = false
        guard let manager else { return }
        manager.stopAdvertising()
        manager.removeAllServices()
        if let psm { manager.unpublishL2CAPChannel(psm) }
        psm = nil
        service = nil
    }

    // MARK: Publishing

    /// Step 1: publish the L2CAP channel (its PSM arrives in `didPublishL2CAPChannel`).
    private func publish() {
        guard running, let manager, manager.state == .poweredOn, psm == nil else { return }
        // No link-layer encryption: that would mean Bluetooth pairing and a system dialog. The
        // transport encrypts every record itself with the phone's link key.
        manager.publishL2CAPChannel(withEncryption: false)
    }

    /// Step 2: the service, with both characteristics answered on read (`didReceiveRead`) so the
    /// tag is always this hour's.
    private func addService() {
        guard let manager, service == nil else { return }
        let psmCharacteristic = CBMutableCharacteristic(
            type: CBUUID(string: BluetoothService.psmCharacteristicUUID), properties: .read, value: nil, permissions: .readable)
        let tagCharacteristic = CBMutableCharacteristic(
            type: CBUUID(string: BluetoothService.tagCharacteristicUUID), properties: .read, value: nil, permissions: .readable)
        let service = CBMutableService(type: CBUUID(string: BluetoothService.serviceUUID), primary: true)
        service.characteristics = [psmCharacteristic, tagCharacteristic]
        self.service = service
        manager.add(service)
    }

    /// Step 3: advertise. Only the service UUID: no name, so the Mac isn't identifiable from the advert.
    private func advertise() {
        guard running, let manager, !manager.isAdvertising else { return }
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BluetoothService.serviceUUID)]])
    }

    // MARK: CBPeripheralManagerDelegate

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            if peripheral.state == .poweredOn {
                publish()
            } else {
                // Bluetooth off (or not allowed): everything published is gone; start over when it's back.
                psm = nil
                service = nil
            }
            onStateChanged?()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, running else { return }
            psm = PSM
            addService()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil else { self.service = nil; return }
            advertise()
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        MainActor.assumeIsolated { onStateChanged?() }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated {
            let value: Data?
            switch request.characteristic.uuid {
            case CBUUID(string: BluetoothService.psmCharacteristicUUID):
                value = psm.map { psm in
                    var be = psm.bigEndian
                    return Data(bytes: &be, count: 2)
                }
            case CBUUID(string: BluetoothService.tagCharacteristicUUID):
                value = BluetoothMacTag.tag(macID: macID, at: Date())
            default:
                value = nil
            }
            guard let value else { return peripheral.respond(to: request, withResult: .attributeNotFound) }
            guard request.offset <= value.count else { return peripheral.respond(to: request, withResult: .invalidOffset) }
            request.value = value.subdata(in: request.offset..<value.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        MainActor.assumeIsolated {
            guard let channel, error == nil, running else { return }
            let keys = self.keys
            let transport = BluetoothTransport(channel: channel, role: .mac { identity in
                keys().first { $0.identity == identity }?.key
            })
            onChannel?(transport)
        }
    }
}
