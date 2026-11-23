import CadenceCore
import Foundation

/// The shape of the working day, as on the iPhone's desk display: before work, focus time, breaks,
/// the end of the day.
extension AppState {
    /// How long "You got focus time!" stays up after a focus stretch ends.
    static let focusCelebrationLength: TimeInterval = 120

    /// Meetings that shape the day: not agenda-only or muted by a clash choice.
    private var dayMeetings: [Meeting] {
        let muted = suppressedByClash
        return muted.isEmpty ? activeMeetings : activeMeetings.filter { !muted.contains($0.id) }
    }

    /// Where we are in the working day. nil when working hours or the menu's day card are off.
    var dayMoment: DayMoment? {
        guard prefs.dayMoments else { return nil }
        return DayPlanner.moment(meetings: dayMeetings, schedule: prefs.workSchedule, now: now, skipping: suppressedByClash)
    }

    /// Minutes of focus time had so far today.
    var focusSoFar: Int {
        DayPlanner.focusSoFar(meetings: dayMeetings, schedule: prefs.workSchedule, now: now)
    }

    /// Minutes of the focus stretch that ended in the last couple of minutes, for "You got focus time!".
    var focusJustEnded: Int? {
        guard prefs.dayMoments else { return nil }
        let stretch = DayPlanner.segments(meetings: dayMeetings, schedule: prefs.workSchedule, day: now, skipping: suppressedByClash)
            .last { $0.kind == .focus && $0.end <= now && now.timeIntervalSince($0.end) < Self.focusCelebrationLength }
        return stretch.map { Int($0.end.timeIntervalSince($0.start) / 60) }
    }
}
