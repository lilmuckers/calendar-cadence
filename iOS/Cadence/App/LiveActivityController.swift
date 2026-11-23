import ActivityKit
import CadenceCore
import Foundation

/// Starts, updates and ends the one Cadence Live Activity.
@MainActor
final class LiveActivityController {
    private var activity: Activity<MeetingActivityAttributes>?
    private var lastState: MeetingActivityAttributes.ContentState?
    /// An ended activity left on the Lock Screen saying "Missed" for a while. Not touched by `end()`
    /// unless asked, so moving on to the next meeting doesn't wipe it straight away.
    private var retiredID: String?

    /// How long a "Missed" activity stays on the Lock Screen after it's ended.
    static let missedDismissDelay: TimeInterval = 15 * 60

    init() {
        // Pick up an activity left over from a previous launch instead of starting a second one.
        activity = Activity<MeetingActivityAttributes>.activities.first { $0.activityState == .active }
        lastState = activity?.content.state
    }

    /// `countdownFrom`: when to swap the start time for a countdown (now, or later for an early start).
    /// `moodMeeting`: the upcoming meeting that drives the icon's mood (the Mac's menu bar stages)
    /// and colour. `missedUntil`: for a meeting with a link, when it stops counting as missed (see
    /// `ActivityPlanner`); `showsMissed`: say "Missed" then rather than going away.
    func show(_ meeting: Meeting, live: Bool, next: Meeting?, onMac: String?, countdownFrom: Date, moodMeeting: Meeting?,
              missedUntil: Date?, showsMissed: Bool) {
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
            iconRed: ic.red, iconGreen: ic.green, iconBlue: ic.blue,
            missedUntil: missedUntil, showsMissed: missedUntil == nil ? nil : showsMissed)
        guard state != lastState else { return }
        retireMissed(unless: meeting.id, now: now)
        lastState = state
        let content = ActivityContent(state: state, staleDate: Self.staleDate(for: state, now: now),
                                      relevanceScore: live || state.missed(now: now) ? 100 : 50)
        apply(content)
    }

    /// Go stale at the next visual switch so the system redraws even while the app is suspended
    /// (it can't update the activity then). Only one date: the countdown taking over for an early
    /// activity; else, for a meeting with a link, the start (when it turns red) and then the end of
    /// its missed time; else the icon's next mood change. Stale never stops a countdown.
    static func staleDate(for state: MeetingActivityAttributes.ContentState, now: Date) -> Date {
        if !state.live, state.countdownFrom > now { return state.countdownFrom }
        if let missedUntil = state.missedUntil {
            return state.start > now ? state.start : max(now, missedUntil)
        }
        return min(state.nextMoodChange(after: now) ?? state.end, state.end)
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
        retireMissed(unless: state.meetingID, now: Date())
        lastState = state
        apply(ActivityContent(state: state, staleDate: segment.end, relevanceScore: 20))
    }

    /// Ends the activity. `keepMissed`: leave a "Missed" one on the Lock Screen for its while.
    func end(keepMissed: Bool = true) {
        if keepMissed { retireMissed(unless: nil, now: Date()) }
        lastState = nil
        activity = nil
        let keep = keepMissed ? retiredID : nil
        if !keepMissed { retiredID = nil }
        for a in Activity<MeetingActivityAttributes>.activities where a.id != keep {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func apply(_ content: ActivityContent<MeetingActivityAttributes.ContentState>) {
        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: MeetingActivityAttributes(), content: content, pushType: nil)
    }

    /// The current activity is a missed meeting whose time is up and should say "Missed": end it
    /// showing that (iOS takes it out of the Dynamic Island and leaves it on the Lock Screen a while),
    /// so a new one can start for whatever's next.
    private func retireMissed(unless meetingID: String?, now: Date) {
        guard let activity, let last = lastState, last.meetingID != meetingID,
              last.showsMissed == true, last.gone(now: now) else { return }
        self.activity = nil
        lastState = nil
        retiredID = activity.id
        let content = ActivityContent(state: last, staleDate: nil, relevanceScore: 10)
        Task { await activity.end(content, dismissalPolicy: .after(now.addingTimeInterval(Self.missedDismissDelay))) }
    }
}
