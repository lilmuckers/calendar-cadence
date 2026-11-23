import CadenceCore
import SwiftUI

/// The menu's line on the working day, like the iPhone's desk display: the googly calendar with a
/// coffee before work, headphones on for focus time, lunch or tea on a break and a wave at the end of
/// the day. "You got focus time!" for a couple of minutes after a focus stretch ends. Nothing while in
/// a meeting or a short gap.
struct DayMomentRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let minutes = state.focusJustEnded {
            row(pose: .focus, title: "You got focus time!",
                detail: "\(DayPlanner.duration(minutes: minutes)) without a meeting.", extra: nil)
        } else if let moment = state.dayMoment, let pose = moment.pose {
            let text = DayPlanner.message(for: moment, now: state.now)
            row(pose: pose, title: text.title, detail: text.detail,
                extra: moment.encouragement(focusSoFar: state.focusSoFar,
                                            focusMinimum: state.prefs.workSchedule.focusMinimumMinutes))
        }
    }

    private func row(pose: MascotPose, title: String, detail: String, extra: String?) -> some View {
        HStack(spacing: 12) {
            GooglyMascot(pose: pose, height: 30)
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let extra {
                    Text(extra)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(pose.propColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(pose.propColor.opacity(0.35)))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(pose.accessibilityLabel). \(title). \(detail)" + (extra.map { ". \($0)" } ?? "")))
    }
}
