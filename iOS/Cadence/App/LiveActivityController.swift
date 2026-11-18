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

    func show(_ meeting: Meeting, live: Bool, next: Meeting?, onMac: String?) {
        let c = meeting.displayColor
        let state = MeetingActivityAttributes.ContentState(
            meetingID: meeting.id, title: meeting.title, start: meeting.start, end: meeting.end, live: live,
            calendarTitle: meeting.calendar.title,
            serviceName: meeting.joinLink?.service.displayName, serviceSymbol: meeting.joinLink?.service.symbol,
            location: meeting.physicalLocation, hasLink: meeting.joinLink != nil,
            red: c.red, green: c.green, blue: c.blue,
            nextTitle: next?.title, nextStart: next?.start, joinsOn: onMac)
        guard state != lastState else { return }
        lastState = state
        let content = ActivityContent(state: state, staleDate: meeting.end)
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
