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
    }

    func remind(_ reminder: Reminder) {
        notifier.notify(reminder)
    }

    func alert(_ meeting: Meeting, forcing style: BusyAlertStyle? = nil) {
        let context = SystemContext.current()
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
        NSLog("Cadence: alert for \(meeting.title): \(plan) — \(SystemContext.describe(context))")

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
