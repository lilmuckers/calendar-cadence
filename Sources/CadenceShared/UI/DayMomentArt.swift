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

    /// A line of encouragement under the report: focus had so far, a reminder that meetings can wait,
    /// a long stretch at the end of the day.
    func encouragement(focusSoFar: Int, focusMinimum: Int) -> String? {
        switch self {
        case .focus:
            focusSoFar >= focusMinimum ? "\(DayPlanner.duration(minutes: focusSoFar)) of focus time so far today" : nil
        case .onBreak:
            "Meetings can wait."
        case .endOfDay(let recap) where recap.longestFocusMinutes >= 90:
            "Longest stretch: \(DayPlanner.duration(minutes: recap.longestFocusMinutes)). Nice!"
        default:
            nil
        }
    }
}
