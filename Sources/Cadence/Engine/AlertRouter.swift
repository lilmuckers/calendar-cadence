import AppKit
import CadenceCore

/// Decides how a due alert is shown — full-screen, banner, notification or not at all —
/// based on whether the user is presenting, sharing their screen or on a call.
@MainActor
final class AlertRouter {
    private let state: AppState
    private let takeover: TakeoverController
    private let banner: BannerController
    private let notifier: Notifier

    init(state: AppState) {
        self.state = state
        takeover = TakeoverController(state: state)
        banner = BannerController(state: state)
        notifier = Notifier(state: state)
        // Handled on the Mac (joined, dismissed, snoozed, timed out) → close it on the phone too.
        takeover.onClosed = { [weak self, weak state] id in
            self?.cancelEscalation(for: id)
            state?.companion.broadcast(.dismissAlert(meetingID: id))
        }
        state.onHandled = { [weak self] id in self?.cancelEscalation(for: id) }
    }

    /// An alert only the phone is showing, due to come up on the Mac if the user's still late.
    private var escalation: (meetingID: String, timer: Timer)?

    private func scheduleEscalation(_ meeting: Meeting) {
        cancelEscalation()
        guard !meeting.id.hasPrefix("preview"),
              let at = state.prefs.companionEscalation.date(start: meeting.start, now: Date()) else { return }
        let timer = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.escalate(meeting) }
        }
        RunLoop.main.add(timer, forMode: .common)
        escalation = (meeting.id, timer)
    }

    private func cancelEscalation(for meetingID: String? = nil) {
        guard let escalation, meetingID == nil || escalation.meetingID == meetingID else { return }
        escalation.timer.invalidate()
        self.escalation = nil
    }

    /// Still late and nothing done on the phone: show the alert the Mac would have shown without it
    /// (so presenting and on-call settings still apply).
    private func escalate(_ meeting: Meeting) {
        escalation = nil
        guard meeting.end > Date() else { return }
        let plan = macPlan(forcing: nil)
        NSLog("Cadence: still late for \(meeting.title), escalating to the Mac: \(plan)")
        show(meeting, plan)
    }

    private var phoneDisplaying: Bool { state.companion.phoneDisplaying }

    func remind(_ reminder: Reminder) {
        if CompanionRouting.macShowsReminders(phoneDisplaying: phoneDisplaying) {
            notifier.notify(reminder)
        } else {
            state.companion.broadcast(.reminder(CompanionReminder(reminder)))
        }
    }

    /// The phone joined, snoozed or dismissed this meeting's alert.
    func closeAlert(for meetingID: String) {
        cancelEscalation(for: meetingID)
        if takeover.currentID == meetingID { takeover.dismiss(notify: false) }
        banner.dismiss()
    }

    func notifyInvites(_ invites: [Meeting]) {
        for m in invites { notifier.notify(invite: m) }
    }

    func alert(_ meeting: Meeting, forcing style: BusyAlertStyle? = nil) {
        let context = SystemContext.current()
        let full = macPlan(forcing: style, context: context)
        let sendToPhone = CompanionRouting.sendsToPhone(connected: state.companion.isConnected, phoneDisplaying: phoneDisplaying)
        if sendToPhone { state.companion.broadcast(.alert(meeting)) }
        let plan = CompanionRouting.macPlan(full, phoneDisplaying: phoneDisplaying, mode: state.prefs.companionTakeover)
        NSLog("Cadence: alert for \(meeting.title): \(plan)\(sendToPhone ? " + iPhone" : "") — \(SystemContext.describe(context))")
        // The Mac held back for the phone: bring it up here too if the user's still late.
        if sendToPhone, plan != full, style == nil { scheduleEscalation(meeting) }
        show(meeting, plan)
    }

    /// What the Mac alone would show right now, before the phone takes its share.
    private func macPlan(forcing style: BusyAlertStyle?, context: AlertContext? = nil) -> AlertPlan {
        let context = context ?? SystemContext.current()
        let prefs = state.prefs
        let plan: AlertPlan
        if let style {
            // Preview: pretend we're busy so the chosen style is used, but still avoid presented displays.
            plan = AlertPolicy.plan(
                context: AlertContext(displays: context.displays, presenting: context.presenting, microphoneApp: "Preview"),
                allScreens: prefs.takeoverAllScreens,
                whilePresenting: style,
                whileOnCall: style
            )
        } else {
            plan = AlertPolicy.plan(
                context: context,
                allScreens: prefs.takeoverAllScreens,
                whilePresenting: prefs.whilePresenting,
                whileOnCall: prefs.whileOnCall
            )
        }
        return plan
    }

    private func show(_ meeting: Meeting, _ plan: AlertPlan) {
        switch plan {
        case .fullScreen(let displays):
            banner.dismiss(animated: false)
            takeover.present(meeting, displays: displays)
        case .banner(let displays):
            takeover.dismiss()
            banner.present(meeting, on: displays.compactMap(SystemContext.screen(for:)))
        case .notification:
            notifier.notify(meeting)
        case .none:
            break
        }
    }
}
