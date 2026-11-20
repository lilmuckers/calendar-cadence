import CadenceCore
import UserNotifications

/// macOS notification fallback. By default macOS hides notifications while the screen is shared
/// or mirrored, which is exactly what we want when every display is being presented.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "cadence.meeting"
    private static let joinAction = "cadence.join"
    private static let inviteCategory = "cadence.invite"
    private static let inviteViewCategory = "cadence.invite.view"
    private static let rsvpPrefix = "cadence.rsvp."

    private let center = UNUserNotificationCenter.current()
    private let state: AppState

    init(state: AppState) {
        self.state = state
        super.init()
        center.delegate = self
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground])
        let replies = RSVP.allCases.map {
            UNNotificationAction(identifier: Self.rsvpPrefix + $0.rawValue, title: $0.label,
                                 options: $0 == .decline ? [.destructive] : [])
        }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [join], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.inviteCategory, actions: replies, intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.inviteViewCategory, actions: [], intentIdentifiers: []),
        ])
    }

    func notify(_ meeting: Meeting) {
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = meeting.title
            let secs = max(0, Int(meeting.start.timeIntervalSinceNow.rounded()))
            content.body = secs > 0
                ? "Starts in \(CountdownFormatter.short(TimeInterval(secs))) · \(meeting.calendar.title)"
                : "Starting now · \(meeting.calendar.title)"
            if state.prefs.takeoverSound { content.sound = .default }
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["meetingID": meeting.id]
            if meeting.joinLink != nil { content.categoryIdentifier = Self.category }
            try? await center.add(UNNotificationRequest(identifier: meeting.id, content: content, trigger: nil))
        }
    }

    func notify(_ reminder: Reminder) {
        let message = ReminderPlanner.message(for: reminder)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["meetingID": reminder.joinTarget.id]
            if reminder.joinTarget.joinLink != nil, !reminder.isSummary, !reminder.isBreak { content.categoryIdentifier = Self.category }
            if reminder.isSummary || reminder.isBreak { content.interruptionLevel = .active }
            try? await center.add(UNNotificationRequest(identifier: reminder.key, content: content, trigger: nil))
        }
    }

    func notify(invite m: Meeting) {
        let canReply = state.canRespond(m)
        let conflicts = state.workConflicts(m)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "New invite: \(m.title)"
            let day = m.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            content.body = [day, m.organizer.map { "from \($0)" }, m.calendar.title].compactMap { $0 }.joined(separator: " · ")
            if let conflict = conflicts.first { content.body += "\n⚠︎ \(conflict)" }
            content.sound = .default
            content.userInfo = ["inviteID": m.id]
            content.categoryIdentifier = canReply ? Self.inviteCategory : Self.inviteViewCategory
            try? await center.add(UNNotificationRequest(identifier: "invite:\(m.id)", content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.content.userInfo["meetingID"] as? String
        let inviteID = response.notification.request.content.userInfo["inviteID"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if let inviteID {
                guard let invite = state.invites.first(where: { $0.id == inviteID }) else { return }
                if action.hasPrefix(Self.rsvpPrefix), let reply = RSVP(rawValue: String(action.dropFirst(Self.rsvpPrefix.count))) {
                    Task { try? await state.respond(invite, reply) }
                } else if action == UNNotificationDefaultActionIdentifier {
                    state.reviewInvites()
                }
                return
            }
            guard let id, let meeting = state.allMeetings.first(where: { $0.id == id }) else { return }
            if action == Self.joinAction || (action == UNNotificationDefaultActionIdentifier && meeting.joinLink != nil) {
                state.join(meeting)
            }
        }
    }
}
