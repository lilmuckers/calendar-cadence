import CadenceCore
import SwiftUI

extension DayMoment {
    /// The mascot for this part of the day; nil while in a meeting or in a short gap.
    var pose: MascotPose? {
        switch self {
        case .beforeWork: .coffee
        case .focus: .focus
        case .onBreak(let b, _): b.isMeal ? .lunch : .tea
        case .endOfDay: .wave
        case .dayOff: .tea
        case .between, .inMeeting: nil
        }
    }

    /// Quiet times, when the desk display can fade back.
    var isRestful: Bool {
        switch self {
        case .beforeWork, .onBreak, .endOfDay, .dayOff: true
        default: false
        }
    }
}

/// The desk display's report on the day: the mascot in the right pose and what's going on.
struct MomentCard: View {
    @Environment(PhoneState.self) private var state
    let moment: DayMoment
    var scale: CGFloat
    /// The drawing's height at scale 1.
    var art: CGFloat = 110

    var body: some View {
        if let pose = moment.pose {
            let text = DayPlanner.message(for: moment, now: state.now)
            VStack(spacing: 14 * scale) {
                GooglyMascot(pose: pose, height: art * scale)
                    .foregroundStyle(.white)
                    .opacity(0.9)
                VStack(spacing: 4) {
                    Text(text.title)
                        .font(.system(size: 20 * scale, weight: .semibold, design: .rounded))
                    Text(text.detail)
                        .font(.system(size: 15 * scale)).foregroundStyle(.white.opacity(0.6))
                    if let extra {
                        Text(extra)
                            .font(.system(size: 13 * scale, weight: .semibold)).foregroundStyle(pose.propColor)
                            .padding(.top, 2)
                    }
                }
                .multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.7)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    /// A line of encouragement under the report.
    private var extra: String? {
        switch moment {
        case .focus:
            let had = state.focusSoFar
            return had >= state.schedule.focusMinimumMinutes ? "\(DayPlanner.duration(minutes: had)) of focus time so far today" : nil
        case .onBreak:
            return "Meetings can wait."
        case .endOfDay(let recap) where recap.longestFocusMinutes >= 90:
            return "Longest stretch: \(DayPlanner.duration(minutes: recap.longestFocusMinutes)). Nice!"
        default:
            return nil
        }
    }
}

/// "You got 1h 30m of focus time!" — shown for a while after a focus stretch ends.
struct FocusCelebration: View {
    let minutes: Int

    var body: some View {
        HStack(spacing: 12) {
            GooglyMascot(pose: .focus, height: 30).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("You got focus time!").font(.system(.headline, design: .rounded))
                Text("\(DayPlanner.duration(minutes: minutes)) without a meeting.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(MascotPose.focus.propColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(MascotPose.focus.propColor.opacity(0.4)))
        .accessibilityElement(children: .combine)
    }
}
