import CadenceCore
import Foundation

enum InviteAlertStyle: String, Codable, CaseIterable, Identifiable {
    case off, notification, card
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Don't alert"
        case .notification: "Notification"
        case .card: "Pop-up card"
        }
    }
}

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
    /// Minutes after the start time an ignored full-screen alert closes itself; 0 = stays until you act.
    var takeoverAutoDismissMinutes = 5
    var whilePresenting: BusyAlertStyle = .banner
    var whileOnCall: BusyAlertStyle = .banner
    var showPanel = true
    var panelHidesWhenIdle = false
    var showMenuBarTitle = true
    var preferNativeApps = true
    var travelMode: TravelMode = .driving
    var icsFeeds: [ICSFeed] = []
    var joinHotKey: HotKeySpec? = .defaultJoin
    var headsUpEnabled = false
    var headsUpMinutes = 5
    var leaveEnabled = true
    /// Minutes before you need to leave; 0 = "time to leave".
    var leaveOffsets: [Int] = [10, 0]
    var clashPromptEnabled = true
    var panelStyle: PanelStyle = .standard
    /// Let AI assistants on this Mac connect through cadence-mcp.
    var mcpEnabled = true
    /// Assistant actions (tool names) that run without asking.
    var mcpAutoApprove: Set<String> = []
    /// Working hours for find_free_time, minutes after midnight.
    var workStart = 9 * 60
    var workEnd = 17 * 60 + 30
    var inviteHorizon: InviteHorizon = .twoDays
    /// Ask about unanswered invites once a day, at the morning summary time.
    var inviteReviewDaily = true
    var newInviteAlert: InviteAlertStyle = .card
    /// Calendars whose invites also ask for an event colour.
    var colorPromptCalendarIDs: Set<String> = []
    /// Colours Cadence keeps itself (for sources that can't store one): seriesID or meeting id → palette id.
    var localEventColors: [String: String] = [:]
    var wrapUpEnabled = true
    var wrapUpMinutes = 5
    var wrapUpOnlyBackToBack = false
    var summaryEnabled = true
    /// Minutes after midnight.
    var summaryTime = 8 * 60 + 30
    var tomorrowPreview = true
    /// Hour from which the agenda also shows tomorrow (it always does once today is done).
    var tomorrowFromHour = 17
    /// Use colours set on individual events (Google, ICS) instead of the calendar colour.
    var useEventColors = true
    /// Step up to a bigger style 15 and 5 minutes before the meeting.
    var panelGrow = false
    /// 0 = always show the next meeting; otherwise only when one starts within this many minutes.
    var panelWithinMinutes = 0
    var panelShowDuringMeetings = true
    /// Single occurrences (Meeting.id) and whole series (Meeting.seriesID) kept off the panel.
    var panelHiddenMeetings: Set<String> = []
    var panelHiddenSeries: Set<String> = []
    /// Which browser profile opens which meeting (default browser only).
    var profileRules = ProfileRules()

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
        takeoverAutoDismissMinutes = try c.decodeIfPresent(Int.self, forKey: .takeoverAutoDismissMinutes) ?? d.takeoverAutoDismissMinutes
        whilePresenting = try c.decodeIfPresent(BusyAlertStyle.self, forKey: .whilePresenting) ?? d.whilePresenting
        whileOnCall = try c.decodeIfPresent(BusyAlertStyle.self, forKey: .whileOnCall) ?? d.whileOnCall
        showPanel = try c.decodeIfPresent(Bool.self, forKey: .showPanel) ?? d.showPanel
        panelHidesWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .panelHidesWhenIdle) ?? d.panelHidesWhenIdle
        showMenuBarTitle = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarTitle) ?? d.showMenuBarTitle
        preferNativeApps = try c.decodeIfPresent(Bool.self, forKey: .preferNativeApps) ?? d.preferNativeApps
        travelMode = try c.decodeIfPresent(TravelMode.self, forKey: .travelMode) ?? d.travelMode
        icsFeeds = try c.decodeIfPresent([ICSFeed].self, forKey: .icsFeeds) ?? d.icsFeeds
        joinHotKey = c.contains(.joinHotKey) ? try c.decodeIfPresent(HotKeySpec.self, forKey: .joinHotKey) : d.joinHotKey
        headsUpEnabled = try c.decodeIfPresent(Bool.self, forKey: .headsUpEnabled) ?? d.headsUpEnabled
        headsUpMinutes = try c.decodeIfPresent(Int.self, forKey: .headsUpMinutes) ?? d.headsUpMinutes
        leaveEnabled = try c.decodeIfPresent(Bool.self, forKey: .leaveEnabled) ?? d.leaveEnabled
        leaveOffsets = try c.decodeIfPresent([Int].self, forKey: .leaveOffsets) ?? d.leaveOffsets
        clashPromptEnabled = try c.decodeIfPresent(Bool.self, forKey: .clashPromptEnabled) ?? d.clashPromptEnabled
        useEventColors = try c.decodeIfPresent(Bool.self, forKey: .useEventColors) ?? d.useEventColors
        mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? d.mcpEnabled
        mcpAutoApprove = try c.decodeIfPresent(Set<String>.self, forKey: .mcpAutoApprove) ?? d.mcpAutoApprove
        workStart = try c.decodeIfPresent(Int.self, forKey: .workStart) ?? d.workStart
        workEnd = try c.decodeIfPresent(Int.self, forKey: .workEnd) ?? d.workEnd
        inviteHorizon = (try? c.decodeIfPresent(InviteHorizon.self, forKey: .inviteHorizon)) ?? d.inviteHorizon
        inviteReviewDaily = try c.decodeIfPresent(Bool.self, forKey: .inviteReviewDaily) ?? d.inviteReviewDaily
        newInviteAlert = (try? c.decodeIfPresent(InviteAlertStyle.self, forKey: .newInviteAlert)) ?? d.newInviteAlert
        colorPromptCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .colorPromptCalendarIDs) ?? d.colorPromptCalendarIDs
        localEventColors = try c.decodeIfPresent([String: String].self, forKey: .localEventColors) ?? d.localEventColors
        wrapUpEnabled = try c.decodeIfPresent(Bool.self, forKey: .wrapUpEnabled) ?? d.wrapUpEnabled
        wrapUpMinutes = try c.decodeIfPresent(Int.self, forKey: .wrapUpMinutes) ?? d.wrapUpMinutes
        wrapUpOnlyBackToBack = try c.decodeIfPresent(Bool.self, forKey: .wrapUpOnlyBackToBack) ?? d.wrapUpOnlyBackToBack
        summaryEnabled = try c.decodeIfPresent(Bool.self, forKey: .summaryEnabled) ?? d.summaryEnabled
        summaryTime = try c.decodeIfPresent(Int.self, forKey: .summaryTime) ?? d.summaryTime
        tomorrowPreview = try c.decodeIfPresent(Bool.self, forKey: .tomorrowPreview) ?? d.tomorrowPreview
        tomorrowFromHour = try c.decodeIfPresent(Int.self, forKey: .tomorrowFromHour) ?? d.tomorrowFromHour
        panelStyle = (try? c.decodeIfPresent(PanelStyle.self, forKey: .panelStyle)) ?? d.panelStyle
        panelGrow = try c.decodeIfPresent(Bool.self, forKey: .panelGrow) ?? d.panelGrow
        panelWithinMinutes = try c.decodeIfPresent(Int.self, forKey: .panelWithinMinutes) ?? d.panelWithinMinutes
        panelShowDuringMeetings = try c.decodeIfPresent(Bool.self, forKey: .panelShowDuringMeetings) ?? d.panelShowDuringMeetings
        panelHiddenMeetings = try c.decodeIfPresent(Set<String>.self, forKey: .panelHiddenMeetings) ?? d.panelHiddenMeetings
        panelHiddenSeries = try c.decodeIfPresent(Set<String>.self, forKey: .panelHiddenSeries) ?? d.panelHiddenSeries
        profileRules = (try? c.decodeIfPresent(ProfileRules.self, forKey: .profileRules)) ?? d.profileRules
    }
}
