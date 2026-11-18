import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CadenceWidgets: WidgetBundle {
    var body: some Widget {
        MeetingLiveActivity()
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
                        GooglyIcon(mood: s.mood(), height: 20).foregroundStyle(.white)
                        Text(s.live ? "Now" : "Next")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(s.tint)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: s, stale: stale).font(.title3.weight(.semibold)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if s.hasLink { JoinLink(state: s) }
                }
            } compactLeading: {
                // The Mac's menu bar icon: calm, then nervous at 15 min, panicking at 5.
                GooglyIcon(mood: s.mood(), height: 16).foregroundStyle(.white)
            } compactTrailing: {
                Countdown(state: s, stale: stale).monospacedDigit().frame(maxWidth: 56)
                    .foregroundStyle(s.counting(stale: stale) ? s.tint : .secondary)
            } minimal: {
                if s.counting(stale: stale) {
                    // Minutes left, ticking: shown when another app also has a Live Activity.
                    Text(timerInterval: Date()...max(Date(), s.target), countsDown: true, showsHours: false)
                        .monospacedDigit().font(.caption2.weight(.semibold)).foregroundStyle(s.tint)
                        .frame(maxWidth: 36)
                } else {
                    GooglyIcon(mood: s.mood(), height: 15).foregroundStyle(.white)
                }
            }
            .widgetURL(s.joinURL)
            .keylineTint(s.tint)
        }
    }
}

private struct LockScreenView: View {
    let state: MeetingActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 3).fill(state.tint).frame(width: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.live ? "ENDS IN" : state.counting(stale: stale) ? "STARTS IN" : "NEXT AT")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                Countdown(state: state, stale: stale)
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
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
        if !state.counting(stale: stale) {
            // Not close yet: just when it starts.
            Text(state.start, style: .time)
        } else if state.target > Date() {
            Text(timerInterval: Date()...state.target, countsDown: true)
        } else {
            Text("Now")
        }
    }
}

private struct JoinLink: View {
    let state: MeetingActivityAttributes.ContentState

    var body: some View {
        Link(destination: state.joinURL) {
            VStack(spacing: 2) {
                Image(systemName: state.serviceSymbol ?? "video.fill").font(.title3)
                Text(state.joinsOn == nil ? "Join" : "Join on Mac").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(state.tint, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

extension MeetingActivityAttributes.ContentState {
    var tint: Color { Color(red: red, green: green, blue: blue) }
}
