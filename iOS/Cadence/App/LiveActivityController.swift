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
    /// `moodStart`: the upcoming start that drives the icon's mood (the Mac's menu bar stages).
    func show(_ meeting: Meeting, live: Bool, next: Meeting?, onMac: String?, countdownFrom: Date, moodStart: Date?) {
        let c = meeting.displayColor
        let now = Date()
        let state = MeetingActivityAttributes.ContentState(
            meetingID: meeting.id, title: meeting.title, start: meeting.start, end: meeting.end, live: live,
            calendarTitle: meeting.calendar.title,
            serviceName: meeting.joinLink?.service.displayName, serviceSymbol: meeting.joinLink?.service.symbol,
            location: meeting.physicalLocation, hasLink: meeting.joinLink != nil,
            red: c.red, green: c.green, blue: c.blue,
            nextTitle: next?.title, nextStart: next?.start, joinsOn: onMac,
            countdownFrom: countdownFrom,
            nervousFrom: moodStart.map { $0.addingTimeInterval(-IconMood.nervousLead) },
            panicFrom: moodStart.map { $0.addingTimeInterval(-IconMood.panicLead) },
            mood: ActivityMood(rawValue: IconMood.forNext(start: moodStart, now: now).rawValue) ?? .calm)
        guard state != lastState else { return }
        lastState = state
        // Go stale at the next visual switch so the system redraws even while the app is suspended:
        // the countdown taking over, else the icon's next mood change. (Stale never stops a countdown.)
        let stale = !live && countdownFrom > now ? countdownFrom : min(state.nextMoodChange(after: now) ?? meeting.end, meeting.end)
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
