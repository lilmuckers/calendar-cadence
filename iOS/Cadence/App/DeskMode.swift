import AudioToolbox
import Foundation
import Observation
import UIKit

/// Desk mode: the always-on, full-screen countdown for a phone on a stand. Turns itself on while
/// charging (there's no public "on a MagSafe stand" API, and charging is the reliable signal),
/// and can be switched on or off by hand; a manual choice lasts until the charging state changes.
@MainActor
@Observable
final class DeskMode {
    private(set) var charging = false
    private var manual: Bool?
    var autoWhenCharging = true { didSet { onChange?() } }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var observer: NSObjectProtocol?

    var isOn: Bool { manual ?? (autoWhenCharging && charging) }

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        charging = Self.isCharging
        observer = NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Self.isCharging
                guard now != self.charging else { return }
                self.charging = now
                self.manual = nil
                self.onChange?()
            }
        }
    }

    func set(_ on: Bool) {
        manual = on == (autoWhenCharging && charging) ? nil : on
        onChange?()
    }

    private static var isCharging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: true
        default: false
        }
    }
}

enum AlertSound {
    /// A short system chime ("Glass"-like); respects the ringer switch.
    static func play() { AudioServicesPlaySystemSound(1013) }
}
