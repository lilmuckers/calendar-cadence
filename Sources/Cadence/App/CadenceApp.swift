import AppKit
import CadenceCore
import SwiftUI

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environment(delegate.state)
        } label: {
            MenuBarLabel(state: delegate.state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(delegate.state)
        }

        Window("About Cadence", id: "about") {
            AboutView()
                .frame(width: 440)
                .fixedSize(horizontal: false, vertical: true)
                .ignoresSafeArea()
                .background(.background)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var panel: CountdownPanelController?
    private var router: AlertRouter?
    private var clashPrompt: ClashPromptController?
    private var inviteReview: InviteReviewController?
    private var phonePrompts: PhonePrompts?
    private var approvals: ApprovalController?
    private var bridge: MCPBridge?
    private var drawer: EnrichmentDrawerController?
    private var welcome: WelcomeWindows?

    /// Double-clicking a .cadconf settings file.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == SettingsArchive.fileExtension {
            SettingsTransfer.importFile(url, into: state)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--screenshots") {
            let dir = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "screenshots"
            ScreenshotRenderer.run(state: state, to: URL(fileURLWithPath: dir))
            NSApp.terminate(nil)
            return
        }
        Keychain.keepOnThisDevice()
        let panel = CountdownPanelController(state: state)
        let router = AlertRouter(state: state)
        self.panel = panel
        self.router = router

        let clashPrompt = ClashPromptController(state: state)
        self.clashPrompt = clashPrompt

        state.onAlert = { meeting, style in router.alert(meeting, forcing: style) }
        state.onReminder = { reminder in router.remind(reminder) }
        state.onTestMediaFade = { router.media.test() }
        let inviteReview = InviteReviewController(state: state)
        self.inviteReview = inviteReview
        let showNewInvitesOnMac: ([Meeting]) -> Void = { [weak self] invites in
            guard let self else { return }
            if self.state.prefs.newInviteAlert == .notification {
                router.notifyInvites(invites)
            } else {
                inviteReview.show(invites, reason: .new)
            }
        }
        // While the iPhone is connected, new invites and clashes pop up there instead of here.
        let phonePrompts = PhonePrompts(state: state, hub: state.companion,
                                        showClashOnMac: { clashPrompt.enqueue($0) },
                                        showInvitesOnMac: showNewInvitesOnMac)
        self.phonePrompts = phonePrompts
        state.onClash = { clash in phonePrompts.clash(clash) }
        state.onInvites = { invites, reason in
            if reason == .new {
                phonePrompts.newInvites(invites)
            } else {
                inviteReview.show(invites, reason: reason)
            }
        }

        let hotKey = GlobalHotKey.shared
        hotKey.action = { [weak self] in self?.state.joinFromHotKey() }
        hotKey.register(state.prefs.joinHotKey)
        var registered = state.prefs.joinHotKey
        let approvals = ApprovalController(state: state)
        let bridge = MCPBridge(state: state, approvals: approvals)
        self.approvals = approvals
        self.bridge = bridge
        MCPBridge.current = bridge
        state.onPrefsChanged = { [weak self] in
            panel.update()
            bridge.sync()
            guard let self, self.state.prefs.joinHotKey != registered else { return }
            registered = self.state.prefs.joinHotKey
            hotKey.register(registered)
        }
        state.start()
        startCompanion(router: router)
        bridge.sync()

        // Re-evaluate panel visibility whenever the observed state it depends on changes.
        observePanel()

        let drawer = EnrichmentDrawerController(state: state)
        self.drawer = drawer
        state.onShowEnrichments = { meeting in drawer.show(meeting) }
        observeDrawer()

        startUpdater(router: router)
    }

    /// Update checks, the first-launch welcome and "What's new" after an update.
    private func startUpdater(router: AlertRouter) {
        let updater = state.updater
        updater.mode = { [weak self] in self?.state.prefs.updateMode }
        // Restart into an update only with no meeting on and none in the next 10 minutes.
        updater.isQuietMoment = { [weak self] in
            guard let state = self?.state else { return true }
            let soon = state.now.addingTimeInterval(10 * 60)
            return !state.activeMeetings.contains { !$0.isAllDay && $0.start < soon && $0.end > state.now }
        }
        updater.onNewVersion = { [weak updater] release in
            router.notifyUpdate(release, canInstall: updater?.canInstall ?? false)
        }
        updater.start()

        let welcome = WelcomeWindows(state: state)
        self.welcome = welcome
        let previous = updater.recordLaunch()
        if state.prefs.updateMode == nil {
            welcome.showWelcome()
        } else if let previous, let current = updater.current, current > previous {
            welcome.showWhatsNew(from: previous)
        }
    }

    private func startCompanion(router: AlertRouter) {
        let hub = state.companion
        hub.snapshot = { [weak self] in self?.state.companionSnapshot() ?? CompanionSnapshot(macName: "", generatedAt: Date(), meetings: []) }
        hub.onJoin = { [weak self] id in
            guard let self, let meeting = self.state.meeting(id: id) else { return }
            self.state.join(meeting)
            router.closeAlert(for: id)
        }
        hub.onSnooze = { [weak self] id, seconds in
            if let meeting = self?.state.meeting(id: id) { self?.state.snooze(meeting, seconds: seconds) }
            router.closeAlert(for: id)
        }
        hub.onDismiss = { id in router.closeAlert(for: id) }
        // Another Mac's meeting, sent here because this Mac is first in the phone's list: open its
        // link here (the Mac's own copy, if it has one, so its browser-profile rules apply).
        hub.onJoinMeeting = { [weak self] meeting in
            guard let self else { return }
            let own = self.state.meetings.first { MeetingDeduplicator.isSameMeeting($0, meeting) }
            // A meeting this Mac doesn't have: open its link only if it's a meeting or web link,
            // the same as links from calendars (never a file or another app's URL scheme).
            var theirs = meeting
            theirs.joinLink = meeting.joinLink.flatMap(MeetingLinkDetector.trusted)
            guard let target = own ?? (theirs.joinLink == nil ? nil : theirs) else { return }
            self.state.join(target)
            if let own { router.closeAlert(for: own.id) }
        }
        hub.onEnrichmentAction = { [weak self] id, action in self?.state.applyEnrichment(action, meetingID: id) }
        if state.prefs.companionEnabled { hub.start() }
        var enabled = state.prefs.companionEnabled
        let previous = state.onPrefsChanged
        state.onPrefsChanged = { [weak self] in
            previous?()
            guard let self, self.state.prefs.companionEnabled != enabled else { return }
            enabled = self.state.prefs.companionEnabled
            if enabled { hub.start() } else { hub.stop() }
        }
    }

    /// The enrichment drawer follows the clock (meetings start and end), the attachments and its settings.
    private func observeDrawer() {
        withObservationTracking {
            _ = state.enrichments.book
            _ = state.prefs.showEnrichmentDrawer
            _ = state.prefs.enrichmentDrawerAutoOpen
            _ = state.enrichmentFocus()?.id
            _ = state.now
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.drawer?.update()
                    self?.observeDrawer()
                }
            }
        }
        drawer?.update()
    }

    private func observePanel() {
        withObservationTracking {
            _ = state.companion.phoneDisplaying
            _ = state.canShowAgenda
            _ = state.prefs.showPanel
            _ = state.prefs.panelHidesWhenIdle
            _ = state.prefs.panelWithinMinutes
            _ = state.panelFocus == nil
            _ = state.panelStyle
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.panel?.update()
                    self?.observePanel()
                }
            }
        }
        panel?.update()
    }
}
