import CadenceCore
import Foundation

/// Shares the Mac's pop-ups that ask for a decision (new invites, clashes) with a connected iPhone.
/// While the phone is on its desk display, Settings → iPhone picks where they show (Mac, phone or
/// both). Otherwise they always show on the Mac (a connected phone can be face down or in a
/// pocket) and wait on the phone too. Settling one on either side clears it from the other, and
/// any shown only on the phone move to the Mac when it leaves desk mode or goes away.
@MainActor
final class PhonePrompts {
    private let state: AppState
    private let hub: CompanionHub
    private let showClashOnMac: (Clash) -> Void
    private let showInvitesOnMac: ([Meeting]) -> Void
    private let dismissClashOnMac: (String) -> Void
    private let dismissInviteOnMac: (String) -> Void

    /// Waiting on the phone, keyed by clash key / invite id.
    private var clashes: [String: Clash] = [:]
    private var invites: [String: Meeting] = [:]
    /// Held back from the Mac because they went to the phone only.
    private var phoneOnlyClashes: Set<String> = []
    private var phoneOnlyInvites: Set<String> = []

    init(state: AppState, hub: CompanionHub,
         showClashOnMac: @escaping (Clash) -> Void, showInvitesOnMac: @escaping ([Meeting]) -> Void,
         dismissClashOnMac: @escaping (String) -> Void, dismissInviteOnMac: @escaping (String) -> Void) {
        self.state = state
        self.hub = hub
        self.showClashOnMac = showClashOnMac
        self.showInvitesOnMac = showInvitesOnMac
        self.dismissClashOnMac = dismissClashOnMac
        self.dismissInviteOnMac = dismissInviteOnMac

        hub.onRSVP = { [weak self] id, reply in self?.answer(id, reply) }
        // "Later" on the phone only puts it away there: the Mac's card stays until dealt with.
        hub.onInviteLater = { [weak self] id in
            guard self?.invites.removeValue(forKey: id) != nil else { return }
            self?.hub.broadcast(.inviteHandled(meetingID: id))
        }
        hub.onResolveClash = { [weak self] key, choice in self?.resolve(key, choice) }
        hub.onPhoneConnected = { [weak self] in self?.resend() }
        hub.onPhonesGone = { [weak self] in self?.handBack() }
        hub.onDisplayChanged = { [weak self] in
            guard let self, !self.hub.phoneDisplaying else { return }
            self.showHeldBack()
        }
        state.onClashResolved = { [weak self] key in self?.settledOnMac(clash: key) }
        state.onInviteAnswered = { [weak self] id in self?.settledOnMac(invite: id) }
    }

    // MARK: Mac → phone

    /// Phone in desk mode and set to "iPhone only": the Mac keeps quiet.
    private var phoneOnly: Bool { hub.phoneDisplaying && state.prefs.promptPlace == .phone }
    /// Send to a connected phone unless set to "This Mac only".
    private var toPhone: Bool { hub.isConnected && state.prefs.promptPlace != .mac }

    func clash(_ clash: Clash) {
        if phoneOnly { phoneOnlyClashes.insert(clash.key) } else { showClashOnMac(clash) }
        guard toPhone else { return }
        clashes[clash.key] = clash
        hub.broadcast(.clashPrompt(CompanionClash(key: clash.key, meetings: clash.meetings)))
    }

    func newInvites(_ meetings: [Meeting]) {
        if phoneOnly { phoneOnlyInvites.formUnion(meetings.map(\.id)) } else { showInvitesOnMac(meetings) }
        guard toPhone else { return }
        for m in meetings { invites[m.id] = m }
        sendInvites(meetings)
    }

    private func sendInvites(_ meetings: [Meeting]) {
        guard !meetings.isEmpty else { return }
        hub.broadcast(.invitePrompt(meetings.map { CompanionInvite(meeting: $0, canRespond: state.canRespond($0), conflicts: state.workConflicts($0)) }))
    }

    /// A phone (re)connected: show it everything still waiting.
    private func resend() {
        prune()
        sendInvites(invites.values.sorted { $0.start < $1.start })
        for clash in clashes.values { hub.broadcast(.clashPrompt(CompanionClash(key: clash.key, meetings: clash.meetings))) }
    }

    /// No phone left: whatever only it was showing comes up on the Mac.
    private func handBack() {
        showHeldBack()
        invites = [:]
        clashes = [:]
    }

    /// The phone left desk mode (or went): prompts it alone had, still unsettled, show on the Mac.
    private func showHeldBack() {
        prune()
        let pendingInvites = invites.values.filter { phoneOnlyInvites.contains($0.id) }.sorted { $0.start < $1.start }
        let pendingClashes = clashes.values.filter { phoneOnlyClashes.contains($0.key) }
        phoneOnlyInvites = []
        phoneOnlyClashes = []
        if !pendingInvites.isEmpty { showInvitesOnMac(pendingInvites) }
        pendingClashes.forEach(showClashOnMac)
    }

    /// Drop prompts that no longer apply (invite answered elsewhere, clash gone or already settled).
    private func prune() {
        let liveInvites = Set(state.invites.map(\.id))
        invites = invites.filter { liveInvites.contains($0.key) }
        let liveClashes = Set(state.clashes.map(\.key))
        clashes = clashes.filter { liveClashes.contains($0.key) && state.clashChoice($0.value) == nil }
    }

    // MARK: Phone → Mac

    private func answer(_ id: String, _ reply: RSVP?) {
        let meeting = invites.removeValue(forKey: id) ?? state.invites.first { $0.id == id }
        hub.broadcast(.inviteHandled(meetingID: id))
        dismissInviteOnMac(id)
        guard let meeting else { return }
        guard let reply else { return state.openInCalendar(meeting) }
        Task { [state] in
            do { try await state.respond(meeting, reply) } catch {
                NSLog("Cadence: RSVP from iPhone for \(meeting.title) failed: \(error.localizedDescription)")
                state.openInCalendar(meeting)
            }
        }
    }

    private func resolve(_ key: String, _ choice: String?) {
        let clash = clashes.removeValue(forKey: key) ?? state.clashes.first { $0.key == key }
        hub.broadcast(.clashHandled(key: key))
        dismissClashOnMac(key)
        if let clash { state.resolveClash(clash, choice: choice) }
    }

    // MARK: Settled on the Mac

    /// The Mac's card was settled (a choice, or "decide later"): take it off the phone too.
    func settledOnMac(clash key: String) {
        guard clashes.removeValue(forKey: key) != nil else { return }
        hub.broadcast(.clashHandled(key: key))
    }

    private func settledOnMac(invite id: String) {
        guard invites.removeValue(forKey: id) != nil else { return }
        hub.broadcast(.inviteHandled(meetingID: id))
    }
}
