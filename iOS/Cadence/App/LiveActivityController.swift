import ActivityKit
import CadenceCore
import Foundation

/// Starts, updates and ends the one Cadence Live Activity.
@MainActor
final class LiveActivityController {
    private var activity: Activity<MeetingActivityAttributes>?
    private var lastState: MeetingActivityAttributes.ContentState?

    init() {
        // Pick up an activity left over from a previous launch instead of starting a second one.
        activity = Activity<MeetingActivityAttributes>.activities.first
    }

    /// `countdownFrom`: when to swap the start time for a countdown (now, or later for an early start).
    func show(_ meeting: Meeting, live: Bool, next: Meeting?, onMac: String?, countdownFrom: Date) {
        let c = meeting.displayColor
        let state = MeetingActivityAttributes.ContentState(
            meetingID: meeting.id, title: meeting.title, start: meeting.start, end: meeting.end, live: live,
            calendarTitle: meeting.calendar.title,
            serviceName: meeting.joinLink?.service.displayName, serviceSymbol: meeting.joinLink?.service.symbol,
            location: meeting.physicalLocation, hasLink: meeting.joinLink != nil,
            red: c.red, green: c.green, blue: c.blue,
            nextTitle: next?.title, nextStart: next?.start, joinsOn: onMac,
            countdownFrom: countdownFrom)
        guard state != lastState else { return }
        lastState = state
        // Waiting to count down: go stale at the switch so the system redraws it as a countdown.
        let stale = !live && countdownFrom > Date() ? countdownFrom : meeting.end
        let content = ActivityContent(state: state, staleDate: stale, relevanceScore: live ? 100 : 50)
        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: MeetingActivityAttributes(), content: content, pushType: nil)
    }

    func end() {
        lastState = nil
        let all = Activity<MeetingActivityAttributes>.activities
        activity = nil
        for a in all { Task { await a.end(nil, dismissalPolicy: .immediate) } }
    }
}
