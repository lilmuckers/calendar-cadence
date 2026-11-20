import CadenceCore
import Foundation

/// Hands the Mac's pop-ups that ask for a decision (new invites, clashes) to the iPhone while it's
/// connected, so they show once, on the phone, instead of on the Mac. Whatever the phone hasn't
/// settled when it goes away pops up on the Mac after all.
@MainActor
final class PhonePrompts {
    private let state: AppState
    private let hub: CompanionHub
    private let showClashOnMac: (Clash) -> Void
    private let showInvitesOnMac: ([Meeting]) -> Void

    /// Waiting on the phone, keyed by clash key / invite id.
    private var clashes: [String: Clash] = [:]
    private var invites: [String: Meeting] = [:]

    init(state: AppState, hub: CompanionHub,
         showClashOnMac: @escaping (Clash) -> Void, showInvitesOnMac: @escaping ([Meeting]) -> Void) {
        self.state = state
        self.hub = hub
        self.showClashOnMac = showClashOnMac
        self.showInvitesOnMac = showInvitesOnMac

        hub.onRSVP = { [weak self] id, reply in self?.answer(id, reply) }
        hub.onInviteLater = { [weak self] id in
            guard self?.invites.removeValue(forKey: id) != nil else { return }
            self?.hub.broadcast(.inviteHandled(meetingID: id))
        }
        hub.onResolveClash = { [weak self] key, choice in self?.resolve(key, choice) }
        hub.onPhoneConnected = { [weak self] in self?.resend() }
        hub.onPhonesGone = { [weak self] in self?.handBack() }
        state.onClashResolved = { [weak self] key in self?.settledOnMac(clash: key) }
        state.onInviteAnswered = { [weak self] id in self?.settledOnMac(invite: id) }
    }

    // MARK: Mac → phone

    func clash(_ clash: Clash) {
        guard hub.isConnected else { return showClashOnMac(clash) }
        clashes[clash.key] = clash
        hub.broadcast(.clashPrompt(CompanionClash(key: clash.key, meetings: clash.meetings)))
    }

    func newInvites(_ meetings: [Meeting]) {
        guard hub.isConnected else { return showInvitesOnMac(meetings) }
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

    /// No phone left: anything unsettled pops up on the Mac instead.
    private func handBack() {
        prune()
        let pendingInvites = invites.values.sorted { $0.start < $1.start }
        let pendingClashes = Array(clashes.values)
        invites = [:]
        clashes = [:]
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
        if let clash { state.resolveClash(clash, choice: choice) }
    }

    // MARK: Settled on the Mac

    private func settledOnMac(clash key: String) {
        guard clashes.removeValue(forKey: key) != nil else { return }
        hub.broadcast(.clashHandled(key: key))
    }

    private func settledOnMac(invite id: String) {
        guard invites.removeValue(forKey: id) != nil else { return }
        hub.broadcast(.inviteHandled(meetingID: id))
    }
}
