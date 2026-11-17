import CadenceCore
import Foundation

enum TravelMode: String, Codable, CaseIterable, Identifiable {
    case driving, walking, transit
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .driving: "car.fill"
        case .walking: "figure.walk"
        case .transit: "tram.fill"
        }
    }
}

/// App-wide settings persisted to UserDefaults as one JSON blob.
struct Preferences: Codable, Equatable {
    var filters = FilterSettings()
    var takeoverEnabled = true
    var takeoverLeadSeconds: Double = 30
    var takeoverAllScreens = true
    var takeoverOnlyWithLink = false
    var takeoverSound = true
    var showPanel = true
    var panelHidesWhenIdle = false
    var showMenuBarTitle = true
    var preferNativeApps = true
    var travelMode: TravelMode = .driving

    private static let key = "Cadence.preferences.v1"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension Preferences {
    // Tolerate older/partial saved blobs: any missing key falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        filters = try c.decodeIfPresent(FilterSettings.self, forKey: .filters) ?? d.filters
        takeoverEnabled = try c.decodeIfPresent(Bool.self, forKey: .takeoverEnabled) ?? d.takeoverEnabled
        takeoverLeadSeconds = try c.decodeIfPresent(Double.self, forKey: .takeoverLeadSeconds) ?? d.takeoverLeadSeconds
        takeoverAllScreens = try c.decodeIfPresent(Bool.self, forKey: .takeoverAllScreens) ?? d.takeoverAllScreens
        takeoverOnlyWithLink = try c.decodeIfPresent(Bool.self, forKey: .takeoverOnlyWithLink) ?? d.takeoverOnlyWithLink
        takeoverSound = try c.decodeIfPresent(Bool.self, forKey: .takeoverSound) ?? d.takeoverSound
        showPanel = try c.decodeIfPresent(Bool.self, forKey: .showPanel) ?? d.showPanel
        panelHidesWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .panelHidesWhenIdle) ?? d.panelHidesWhenIdle
        showMenuBarTitle = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarTitle) ?? d.showMenuBarTitle
        preferNativeApps = try c.decodeIfPresent(Bool.self, forKey: .preferNativeApps) ?? d.preferNativeApps
        travelMode = try c.decodeIfPresent(TravelMode.self, forKey: .travelMode) ?? d.travelMode
    }
}
