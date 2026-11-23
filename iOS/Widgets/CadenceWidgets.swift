import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CadenceWidgets: WidgetBundle {
    var body: some Widget {
        MeetingLiveActivity()
        NextMeetingWidget()
    }
}

/// Lock Screen / StandBy / Dynamic Island countdown with a Join button.
struct MeetingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingActivityAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        StateIcon(state: s, height: 20)
                        Text(s.isMoment ? "Left" : s.gone() ? (s.showsMissed == true ? "Missed" : "Over")
                             : s.missed() ? "Late" : s.live ? "Now" : "Next")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(s.missed() || (s.gone() && s.showsMissed == true) ? Color.missed : s.tint)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: s, stale: stale).font(.title3.weight(.semibold)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if s.hasLink, !s.gone() { JoinLink(state: s) }
                    else if let detail = s.momentDetail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            } compactLeading: {
                // The Mac's menu bar icon: calm, then nervous at 15 min, panicking at 5.
                StateIcon(state: s, height: 16)
            } compactTrailing: {
                Countdown(state: s, stale: stale).monospacedDigit().frame(maxWidth: 56)
                    .foregroundStyle(s.countdownTint(stale: stale))
            } minimal: {
                if s.gone() {
                    StateIcon(state: s, height: 15)
                } else if s.missed() {
                    Countdown(state: s, stale: stale).monospacedDigit().font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.missed).frame(maxWidth: 36)
                } else if s.counting(stale: stale) {
                    // Minutes left, ticking: shown when another app also has a Live Activity.
                    Text(timerInterval: Date()...max(Date(), s.target), countsDown: true, showsHours: false)
                        .monospacedDigit().font(.caption2.weight(.semibold)).foregroundStyle(s.tint)
                        .frame(maxWidth: 36)
                } else {
                    StateIcon(state: s, height: 15)
                }
            }
            .widgetURL(s.isMoment ? URL(string: "cadence-companion://open") : s.joinURL)
            .keylineTint(s.tint)
        }
    }
}

/// The googly icon for a meeting, or the mascot in its pose for focus time and breaks.
private struct StateIcon: View {
    let state: MeetingActivityAttributes.ContentState
    var height: CGFloat

    var body: some View {
        if let pose = state.pose {
            GooglyMascot(pose: pose, height: height, animated: false).foregroundStyle(.white)
        } else {
            GooglyIcon(mood: state.mood(), height: height)
                .foregroundStyle(state.missed() ? Color.missed : state.iconTint)
        }
    }
}

private struct LockScreenView: View {
    let state: MeetingActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        if state.gone() {
            goneBody
        } else if let pose = state.pose {
            HStack(alignment: .center, spacing: 14) {
                GooglyMascot(pose: pose, height: 48, animated: false).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(state.title.uppercased()) · LEFT")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                    Countdown(state: state, stale: stale)
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                    Text(state.momentDetail ?? "").font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        } else {
            meetingBody
        }
    }

    /// A missed meeting whose time is up, before the app gets to take the activity down: "Missed"
    /// with a disappointed icon, or (when the user would rather it just went) a single quiet line.
    @ViewBuilder private var goneBody: some View {
        if state.showsMissed == true {
            HStack(alignment: .center, spacing: 14) {
                GooglyIcon(mood: .disappointed, height: 44).foregroundStyle(state.iconTint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MISSED").font(.caption2.weight(.bold)).foregroundStyle(Color.missed)
                    Text(state.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text("\(state.start.formatted(date: .omitted, time: .shortened)) · not joined")
                        .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        } else {
            Text(state.title).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private var meetingBody: some View {
        let missed = state.missed()
        return HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 3).fill(missed ? Color.missed : state.tint).frame(width: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(missed ? "STARTED" : state.live ? "ENDS IN" : state.counting(stale: stale) ? "STARTS IN" : "NEXT AT")
                    .font(.caption2.weight(.bold)).foregroundStyle(missed ? Color.missed : .white.opacity(0.6))
                Countdown(state: state, stale: stale)
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(missed ? Color.missed : .white)
                Text(state.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if state.hasLink { JoinLink(state: state) }
        }
        .padding(16)
    }

    private var subtitle: String {
        var parts = [state.start.formatted(date: .omitted, time: .shortened), state.serviceName ?? state.location ?? state.calendarTitle]
        if let next = state.nextTitle, let at = state.nextStart { parts.append("then \(next) \(at.formatted(date: .omitted, time: .shortened))") }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

private struct Countdown: View {
    let state: MeetingActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        if state.gone() {
            Text(state.showsMissed == true ? "Missed" : "")
        } else if state.missed() {
            // Started without a join: counts on past zero, as minus how late it is.
            Text("−\(Text(timerInterval: state.start...state.start.addingTimeInterval(12 * 3600), countsDown: false))")
        } else if !state.counting(stale: stale) {
            // Not close yet: just when it starts.
            Text(state.start, style: .time)
        } else if state.target > Date() {
            Text(timerInterval: Date()...state.target, countsDown: true)
        } else {
            Text(state.isMoment ? "Done" : "Now")
        }
    }
}

private struct JoinLink: View {
    let state: MeetingActivityAttributes.ContentState

    var body: some View {
        Link(destination: state.joinURL) {
            VStack(spacing: 2) {
                Image(systemName: state.serviceSymbol ?? "video.fill").font(.title3)
                Text(state.joinsOn.map { "Join on \($0)" } ?? "Join").lineLimit(1).font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(state.tint, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

extension Color {
    /// A meeting that started without anyone joining.
    static let missed = Color(red: 1.0, green: 0.27, blue: 0.23)
}

extension MeetingActivityAttributes.ContentState {
    var tint: Color { Color(red: red, green: green, blue: blue) }

    /// The countdown's colour in the Dynamic Island.
    func countdownTint(stale: Bool) -> Color {
        if gone() { return showsMissed == true ? .missed : .secondary }
        if missed() { return .missed }
        return counting(stale: stale) ? tint : .secondary
    }

    /// The googly icon's colour: the approaching meeting's calendar, lifted towards white when it's
    /// too dark to see against the black Dynamic Island.
    var iconTint: Color {
        var (r, g, b) = (iconRed ?? red, iconGreen ?? green, iconBlue ?? blue)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if luminance < 0.4 {
            let lift = (0.4 - luminance) / 0.4 * 0.5
            (r, g, b) = (r + (1 - r) * lift, g + (1 - g) * lift, b + (1 - b) * lift)
        }
        return Color(red: r, green: g, blue: b)
    }
}
