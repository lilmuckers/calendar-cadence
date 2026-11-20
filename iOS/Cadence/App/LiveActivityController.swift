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
    /// `moodMeeting`: the upcoming meeting that drives the icon's mood (the Mac's menu bar stages)
    /// and colour.
    func show(_ meeting: Meeting, live: Bool, next: Meeting?, onMac: String?, countdownFrom: Date, moodMeeting: Meeting?) {
        let c = meeting.displayColor
        let ic = (moodMeeting ?? meeting).displayColor
        let moodStart = moodMeeting?.start
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
            mood: ActivityMood(rawValue: IconMood.forNext(start: moodStart, now: now).rawValue) ?? .calm,
            iconRed: ic.red, iconGreen: ic.green, iconBlue: ic.blue)
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

    /// Counts down a focus stretch or break, with the mascot in the matching pose.
    func show(segment: WidgetSegment, next: Meeting?) {
        let pose = segment.pose
        let tint: (Double, Double, Double) = switch pose {
        case .focus: (0.45, 0.72, 1.0)
        case .lunch: (0.96, 0.76, 0.42)
        default: (0.93, 0.62, 0.38)
        }
        let state = MeetingActivityAttributes.ContentState(
            meetingID: "moment:\(segment.kind):\(Int(segment.start.timeIntervalSince1970))", title: segment.title,
            start: segment.start, end: segment.end, live: true,
            calendarTitle: "Cadence", serviceName: nil, serviceSymbol: nil, location: nil, hasLink: false,
            red: tint.0, green: tint.1, blue: tint.2,
            nextTitle: next?.title, nextStart: next?.start, joinsOn: nil,
            countdownFrom: segment.start, nervousFrom: nil, panicFrom: nil, mood: .calm,
            iconRed: tint.0, iconGreen: tint.1, iconBlue: tint.2,
            pose: pose, momentDetail: segment.detail)
        guard state != lastState else { return }
        lastState = state
        let content = ActivityContent(state: state, staleDate: segment.end, relevanceScore: 20)
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
