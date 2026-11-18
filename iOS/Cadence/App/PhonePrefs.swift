import CadenceCore
import Foundation

/// iPhone settings, persisted to UserDefaults as one JSON blob. Missing keys fall back to defaults.
struct PhonePrefs: Codable, Equatable {
    var filters = FilterSettings()
    var icsFeeds: [ICSFeed] = []

    // Full-screen alert (used when not connected to the Mac; the Mac decides when connected).
    var takeoverEnabled = true
    var takeoverLeadSeconds: Double = 30
    var takeoverOnlyWithLink = false
    var alertSound = true

    // Notifications while Cadence isn't on screen.
    var backgroundNotifications = true
    var headsUpEnabled = true
    var headsUpMinutes = 5
    var wrapUpEnabled = false
    var wrapUpMinutes = 5

    // Desk mode.
    /// Go to desk mode on its own while charging (e.g. on a MagSafe stand).
    var deskWhenCharging = true
    /// Dim the desk display between meetings.
    var deskDimWhenIdle = true

    // Live Activity on the Lock Screen / StandBy.
    var liveActivityEnabled = true
    var liveActivityLeadMinutes = 30

    private static let key = "Cadence.phone.preferences.v1"

    static func load() -> PhonePrefs {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(PhonePrefs.self, from: data) else { return PhonePrefs() }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension PhonePrefs {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PhonePrefs()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        filters = v(.filters, d.filters)
        icsFeeds = v(.icsFeeds, d.icsFeeds)
        takeoverEnabled = v(.takeoverEnabled, d.takeoverEnabled)
        takeoverLeadSeconds = v(.takeoverLeadSeconds, d.takeoverLeadSeconds)
        takeoverOnlyWithLink = v(.takeoverOnlyWithLink, d.takeoverOnlyWithLink)
        alertSound = v(.alertSound, d.alertSound)
        backgroundNotifications = v(.backgroundNotifications, d.backgroundNotifications)
        headsUpEnabled = v(.headsUpEnabled, d.headsUpEnabled)
        headsUpMinutes = v(.headsUpMinutes, d.headsUpMinutes)
        wrapUpEnabled = v(.wrapUpEnabled, d.wrapUpEnabled)
        wrapUpMinutes = v(.wrapUpMinutes, d.wrapUpMinutes)
        deskWhenCharging = v(.deskWhenCharging, d.deskWhenCharging)
        deskDimWhenIdle = v(.deskDimWhenIdle, d.deskDimWhenIdle)
        liveActivityEnabled = v(.liveActivityEnabled, d.liveActivityEnabled)
        liveActivityLeadMinutes = v(.liveActivityLeadMinutes, d.liveActivityLeadMinutes)
    }
}
