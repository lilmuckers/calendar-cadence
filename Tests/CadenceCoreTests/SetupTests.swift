import Testing
@testable import CadenceCore

@Suite struct AlertPresetTests {
    @Test func eachPresetMatchesItself() {
        for preset in AlertPreset.allCases {
            #expect(AlertPreset.matching(preset.settings) == preset)
        }
    }

    @Test func normalIsTheAppDefaults() {
        // Preferences() defaults: full screen 30 s before, closes 5 min after, no heads-up.
        let defaults = AlertSettings(takeoverEnabled: true, takeoverLeadSeconds: 30, takeoverAutoDismissMinutes: 5,
                                     headsUpEnabled: false, headsUpMinutes: 5)
        #expect(AlertPreset.matching(defaults) == .normal)
    }

    @Test func settingsAPresetHidesDontCount() {
        var s = AlertPreset.gentle.settings
        s.takeoverLeadSeconds = 300  // full screen is off, so its lead time is irrelevant
        s.takeoverAutoDismissMinutes = 0
        #expect(AlertPreset.matching(s) == .gentle)
        var n = AlertPreset.normal.settings
        n.headsUpMinutes = 10  // heads-up is off in Normal
        #expect(AlertPreset.matching(n) == .normal)
    }

    @Test func handTunedSettingsMatchNoPreset() {
        var s = AlertPreset.normal.settings
        s.takeoverLeadSeconds = 120
        #expect(AlertPreset.matching(s) == nil)
        var g = AlertPreset.gentle.settings
        g.headsUpMinutes = 10
        #expect(AlertPreset.matching(g) == nil)
    }

    @Test func onlyGentleStaysOffTheScreen() {
        #expect(!AlertPreset.gentle.takesOverScreen)
        #expect(AlertPreset.normal.takesOverScreen)
        #expect(AlertPreset.insistent.takesOverScreen)
    }
}

@Suite struct SetupTaskTests {
    @Test func nothingOpenWhenEverythingIsSetUp() {
        #expect(SetupTask.open(hasCalendars: true, notificationsAllowed: true).isEmpty)
    }

    @Test func skippedStepsStayOpenInOrder() {
        #expect(SetupTask.open(hasCalendars: false, notificationsAllowed: false) == [.connectCalendar, .allowNotifications])
    }

    @Test func unknownNotificationStatusIsNotATask() {
        #expect(SetupTask.open(hasCalendars: true, notificationsAllowed: nil).isEmpty)
    }
}
