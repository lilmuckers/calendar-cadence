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
    /// Minutes after the start an ignored alert closes by itself; 0 = never (as on the Mac).
    var takeoverAutoDismissMinutes = 5

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
    /// Media controls in the corner of the landscape desk display.
    var deskMediaControls = true
    /// A "Notes" button on the desk display when an assistant attached things to the meeting.
    var deskEnrichments = true
    /// Open those notes on their own when the meeting starts.
    var deskEnrichmentsAutoOpen = false
    /// Opened by the desk's media button, and the look of the controls. `.system` follows
    /// whatever's playing instead of a particular app.
    var mediaApp: MediaApp = .system
    /// A meeting alert fades out music playing on this phone and hands the headphones over.
    var pauseMediaForAlerts = true
    /// ...and says which meeting it is before letting go.
    var announceAlerts = true

    // Live Activity on the Lock Screen / StandBy.
    var liveActivityEnabled = true
    var liveActivityLeadMinutes = 30
    /// A meeting with a link that started without a join counts up in red, then goes away after this.
    var liveActivityMissedLinger: MissedMeetingLinger = .fiveMinutes
    /// When that time's up, say "Missed" (with a disappointed icon) on the Lock Screen for a while
    /// instead of disappearing.
    var liveActivityShowsMissed = false

    // Home Screen / Lock Screen widgets.
    /// With nothing left today, show tomorrow's first meeting from `widgetTomorrowHour` on.
    var widgetShowsTomorrow = true
    var widgetTomorrowHour = 20

    /// Working hours and breaks, used when not connected to the Mac (the Mac's win while it is).
    var workSchedule = WorkSchedule()

    /// Paired with several Macs: a meeting only one Mac has, with a link any browser opens, joins on
    /// the first Mac in the list rather than the one it came from.
    var joinOnPriorityMac = false
    /// Reach the Mac over Bluetooth when the network can't (a last resort; Wi-Fi is always tried first).
    var useBluetooth = true

    /// "Try with sample meetings": when it was turned on, nil while it's off.
    var sampleCalendarSince: Date?
    /// The first-launch welcome has been finished or skipped.
    var welcomeSeen = false

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
        takeoverAutoDismissMinutes = v(.takeoverAutoDismissMinutes, d.takeoverAutoDismissMinutes)
        backgroundNotifications = v(.backgroundNotifications, d.backgroundNotifications)
        headsUpEnabled = v(.headsUpEnabled, d.headsUpEnabled)
        headsUpMinutes = v(.headsUpMinutes, d.headsUpMinutes)
        wrapUpEnabled = v(.wrapUpEnabled, d.wrapUpEnabled)
        wrapUpMinutes = v(.wrapUpMinutes, d.wrapUpMinutes)
        deskWhenCharging = v(.deskWhenCharging, d.deskWhenCharging)
        deskDimWhenIdle = v(.deskDimWhenIdle, d.deskDimWhenIdle)
        deskMediaControls = v(.deskMediaControls, d.deskMediaControls)
        deskEnrichments = v(.deskEnrichments, d.deskEnrichments)
        deskEnrichmentsAutoOpen = v(.deskEnrichmentsAutoOpen, d.deskEnrichmentsAutoOpen)
        mediaApp = v(.mediaApp, d.mediaApp)
        pauseMediaForAlerts = v(.pauseMediaForAlerts, d.pauseMediaForAlerts)
        announceAlerts = v(.announceAlerts, d.announceAlerts)
        liveActivityEnabled = v(.liveActivityEnabled, d.liveActivityEnabled)
        liveActivityLeadMinutes = v(.liveActivityLeadMinutes, d.liveActivityLeadMinutes)
        liveActivityMissedLinger = v(.liveActivityMissedLinger, d.liveActivityMissedLinger)
        liveActivityShowsMissed = v(.liveActivityShowsMissed, d.liveActivityShowsMissed)
        widgetShowsTomorrow = v(.widgetShowsTomorrow, d.widgetShowsTomorrow)
        widgetTomorrowHour = v(.widgetTomorrowHour, d.widgetTomorrowHour)
        workSchedule = v(.workSchedule, d.workSchedule)
        joinOnPriorityMac = v(.joinOnPriorityMac, d.joinOnPriorityMac)
        useBluetooth = v(.useBluetooth, d.useBluetooth)
        sampleCalendarSince = v(.sampleCalendarSince, d.sampleCalendarSince)
        welcomeSeen = v(.welcomeSeen, d.welcomeSeen)
    }
}
