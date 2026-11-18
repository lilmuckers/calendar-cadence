import CadenceCore
import Foundation
import UserNotifications

/// Local notifications scheduled ahead of time, so alerts and reminders still arrive while Cadence
/// is suspended (iOS doesn't let apps run timers in the background).
@MainActor
final class PhoneNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "cadence.meeting"
    static let joinAction = "cadence.join"
    private static let prefix = "cadence.sched."
    /// iOS keeps at most 64 pending notifications per app.
    private static let limit = 60

    var onJoin: ((String) -> Void)?
    /// While true (app on screen) scheduled notifications aren't shown: the app shows its own alert.
    var isForegroundSuppressed: (() -> Bool)?

    private let center = UNUserNotificationCenter.current()

    func setUp() {
        center.delegate = self
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [join], intentIdentifiers: [])])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replaces every scheduled notification with ones for `meetings`.
    func reschedule(meetings: [Meeting], prefs: PhonePrefs) {
        let now = Date()
        var requests: [UNNotificationRequest] = []
        if prefs.backgroundNotifications {
            let upcoming = meetings.filter { !$0.isAllDay && !$0.isCanceled && $0.start > now }
            if prefs.takeoverEnabled {
                for m in upcoming where !prefs.takeoverOnlyWithLink || m.joinLink != nil {
                    let secs = Int(prefs.takeoverLeadSeconds)
                    requests += request("alert:\(m.id)", at: m.start.addingTimeInterval(-prefs.takeoverLeadSeconds),
                                        title: m.title,
                                        body: secs >= 60 ? "Starts in \(secs / 60) min" : "Starting now · \(m.joinLink?.service.displayName ?? m.calendar.title)",
                                        meeting: m, timeSensitive: true)
                }
            }
            var reminders: [Reminder] = []
            if prefs.headsUpEnabled { reminders += ReminderPlanner.headsUps(for: upcoming, minutes: prefs.headsUpMinutes) }
            if prefs.wrapUpEnabled {
                let timed = meetings.filter { !$0.isAllDay && $0.end > now && $0.participation != .declined }
                reminders += ReminderPlanner.wrapUps(live: timed, all: meetings, minutes: prefs.wrapUpMinutes, onlyBackToBack: false)
            }
            for r in reminders where r.fireAt > now {
                let text = ReminderPlanner.message(for: r)
                requests += request(r.key, at: r.fireAt, title: text.title, body: text.body, meeting: r.joinTarget, timeSensitive: false)
            }
        }
        requests = Array(requests.sorted { trigger($0) < trigger($1) }.prefix(Self.limit))

        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            guard !requests.isEmpty, await requestAuthorization() else { return }
            for r in requests { try? await center.add(r) }
        }
    }

    private func trigger(_ r: UNNotificationRequest) -> Date {
        (r.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
    }

    private func request(_ key: String, at date: Date, title: String, body: String, meeting: Meeting, timeSensitive: Bool) -> [UNNotificationRequest] {
        let interval = date.timeIntervalSinceNow
        guard interval > 1 else { return [] }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = timeSensitive ? .timeSensitive : .active
        content.threadIdentifier = meeting.id
        if meeting.joinLink != nil {
            content.categoryIdentifier = Self.category
            content.userInfo = ["meetingID": meeting.id]
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        return [UNNotificationRequest(identifier: Self.prefix + key, content: content, trigger: trigger)]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let suppressed = await MainActor.run { isForegroundSuppressed?() ?? false }
        return suppressed ? [] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["meetingID"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let id, action == Self.joinAction else { return }
            onJoin?(id)
        }
    }
}
