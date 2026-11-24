import SwiftUI
import WidgetKit

/// Home Screen, Today view, StandBy and Lock Screen widget: how long until the next meeting today
/// (or, during one, how long it has left, until the next is ten minutes off),
/// or "No more meetings today!" once there isn't one (in the evening, when tomorrow's first meeting is). Reads the schedule the app saves to the App
/// Group; the countdown is a system timer, so it ticks without timeline reloads.
struct NextMeetingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextMeeting", provider: NextMeetingProvider()) { entry in
            NextMeetingView(entry: entry)
        }
        .configurationDisplayName("Next Meeting")
        .description("Time until your next meeting today.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct NextMeetingEntry: TimelineEntry {
    let date: Date
    /// A meeting in progress, shown instead of the next one until that's close (as in the app).
    let live: WidgetMeeting?
    let next: WidgetMeeting?
    let following: WidgetMeeting?
    /// Tomorrow's first meeting, set only in the evening once nothing is left today.
    let tomorrow: WidgetMeeting?
    let mood: ActivityMood
    /// Focus time, a break, before or after work, when no meeting is live or close.
    let segment: WidgetSegment?
    /// No schedule saved yet (app not opened since install, or no App Group).
    let unknown: Bool

    init(date: Date, schedule: WidgetSchedule?) {
        self.date = date
        unknown = schedule == nil
        live = schedule?.live(at: date)
        next = schedule?.next(after: date)
        following = next.flatMap { schedule?.following($0) }
        tomorrow = schedule?.tomorrowFirst(after: date)
        mood = schedule?.mood(at: date) ?? .calm
        segment = schedule?.segment(at: date)
    }

    static let placeholder = NextMeetingEntry(date: Date(), schedule: WidgetSchedule(meetings: [
        WidgetMeeting(id: "placeholder", title: "Design Review", start: Date().addingTimeInterval(23 * 60),
                      end: Date().addingTimeInterval(53 * 60), red: 0.35, green: 0.55, blue: 0.95, hasLink: true),
    ], generatedAt: Date()))
}

struct NextMeetingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextMeetingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (NextMeetingEntry) -> Void) {
        let schedule = WidgetSchedule.load()
        // The gallery shows a sample when there's nothing real to preview.
        if context.isPreview, schedule?.live(at: Date()) == nil, schedule?.next(after: Date()) == nil, schedule?.tomorrowFirst(after: Date()) == nil {
            return completion(.placeholder)
        }
        completion(NextMeetingEntry(date: Date(), schedule: schedule))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextMeetingEntry>) -> Void) {
        let now = Date()
        let schedule = WidgetSchedule.load()
        let dates = schedule?.entryDates(from: now) ?? [now]
        let entries = dates.map { NextMeetingEntry(date: $0, schedule: schedule) }
        // The app reloads the widget on every change, but iOS rations reloads asked for from the
        // background and can drop them, leaving a timeline built from an older schedule. So also come
        // back on our own every so often to pick up whatever the app saved since.
        let refresh = min(dates.last.flatMap { $0 > now ? $0 : nil } ?? .distantFuture, now.addingTimeInterval(WidgetSchedule.refreshInterval))
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

// MARK: - Views

private let doneText = "No more meetings today!"

struct NextMeetingView: View {
    let entry: NextMeetingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if family == .systemSmall || family == .systemMedium {
                    LinearGradient(colors: [Color(white: 0.13), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                } else {
                    Color.clear
                }
            }
            .widgetURL(URL(string: "cadence-companion://open"))
    }

    @ViewBuilder private var content: some View {
        if let seg = entry.segment {
            MomentWidgetView(segment: seg, family: family, date: entry.date)
        } else {
            meetingContent
        }
    }

    @ViewBuilder private var meetingContent: some View {
        if let live = entry.live {
            LiveMeetingView(entry: entry, meeting: live, family: family)
        } else {
            nextContent
        }
    }

    @ViewBuilder private var nextContent: some View {
        switch family {
        case .systemMedium: MediumView(entry: entry)
        case .accessoryRectangular: RectangularView(entry: entry)
        case .accessoryCircular: CircularView(entry: entry)
        case .accessoryInline: InlineView(entry: entry)
        default: SmallView(entry: entry)
        }
    }
}

private struct SmallView: View {
    let entry: NextMeetingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                GooglyIcon(mood: entry.mood, height: 18).foregroundStyle(iconTint(entry.next ?? entry.tomorrow))
                Spacer(minLength: 0)
                if let next = entry.next {
                    Text(next.start, style: .time).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
            if let next = entry.next {
                Text("NEXT IN").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                CountdownText(target: next.start)
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .foregroundStyle(.white)
                Text(next.title).font(.subheadline.weight(.semibold)).foregroundStyle(next.tint).lineLimit(2)
            } else if let first = entry.tomorrow {
                Text("FIRST TOMORROW").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                Text(first.start, style: .time)
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .foregroundStyle(.white)
                Text(first.title).font(.subheadline.weight(.semibold)).foregroundStyle(first.tint).lineLimit(2)
            } else {
                DoneText(unknown: entry.unknown).font(.headline).foregroundStyle(.white)
            }
        }
    }
}

private struct MediumView: View {
    let entry: NextMeetingEntry

    var body: some View {
        if let next = entry.next {
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 3).fill(next.tint).frame(width: 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        GooglyIcon(mood: entry.mood, height: 16).foregroundStyle(iconTint(next))
                        Text("NEXT IN").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                    }
                    CountdownText(target: next.start)
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(.white)
                    Text(next.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(subtitle(next)).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if next.hasLink {
                    Link(destination: next.joinURL) {
                        VStack(spacing: 2) {
                            Image(systemName: "video.fill").font(.title3)
                            Text("Join").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(next.tint, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        } else if let first = entry.tomorrow {
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 3).fill(first.tint).frame(width: 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        GooglyIcon(mood: .calm, height: 16).foregroundStyle(iconTint(first))
                        Text("YOUR FIRST MEETING TOMORROW IS AT").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Text(first.start, style: .time)
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(.white)
                    Text(first.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(doneText).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 14) {
                GooglyIcon(mood: .calm, height: 40).foregroundStyle(.white)
                DoneText(unknown: entry.unknown).font(.title3.weight(.semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
            }
        }
    }

    private func subtitle(_ next: WidgetMeeting) -> String {
        var parts = [next.start.formatted(date: .omitted, time: .shortened)]
        if let then = entry.following { parts.append("then \(then.title) \(then.start.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: " · ")
    }
}

private struct RectangularView: View {
    let entry: NextMeetingEntry

    var body: some View {
        if let next = entry.next {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    GooglyIcon(mood: entry.mood, height: 12)
                    Text("Next in").font(.caption.weight(.semibold))
                    CountdownText(target: next.start).font(.caption.weight(.semibold)).monospacedDigit()
                }
                Text(next.title).font(.headline).lineLimit(1).widgetAccentable()
                Text(next.start, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let first = entry.tomorrow {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    GooglyIcon(mood: .calm, height: 12)
                    Text("First tomorrow").font(.caption.weight(.semibold))
                }
                Text(first.title).font(.headline).lineLimit(1).widgetAccentable()
                Text(first.start, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                GooglyIcon(mood: .calm, height: 18)
                DoneText(unknown: entry.unknown).font(.headline).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CircularView: View {
    let entry: NextMeetingEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let next = entry.next {
                VStack(spacing: 0) {
                    GooglyIcon(mood: entry.mood, height: 11)
                    CountdownText(target: next.start, showsHours: false)
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .multilineTextAlignment(.center).minimumScaleFactor(0.5).lineLimit(1)
                        .padding(.horizontal, 4)
                }
            } else if let first = entry.tomorrow {
                VStack(spacing: 0) {
                    Text("TMRW").font(.system(size: 8, weight: .bold))
                    Text(first.start.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1)
                        .padding(.horizontal, 4)
                }
                .accessibilityLabel("First meeting tomorrow at \(first.start.formatted(date: .omitted, time: .shortened))")
            } else {
                VStack(spacing: 1) {
                    GooglyIcon(mood: .calm, height: 16)
                    Text("Done").font(.system(size: 10, weight: .semibold))
                }
                .accessibilityLabel(doneText)
            }
        }
    }
}

private struct InlineView: View {
    let entry: NextMeetingEntry

    var body: some View {
        if let next = entry.next {
            // Inline widgets take one Text; the embedded timer keeps itself current.
            Text("\(next.title) in \(Text(timerInterval: entry.date...max(entry.date, next.start), countsDown: true))")
        } else if let first = entry.tomorrow {
            Text("Tomorrow \(first.start.formatted(date: .omitted, time: .shortened)): \(first.title)")
        } else {
            DoneText(unknown: entry.unknown)
        }
    }
}

/// A meeting in progress: counting down to its end, with what's next.
private struct LiveMeetingView: View {
    let entry: NextMeetingEntry
    let meeting: WidgetMeeting
    let family: WidgetFamily

    private var thenText: String? {
        entry.next.map { "then \($0.title) \($0.start.formatted(date: .omitted, time: .shortened))" }
    }

    var body: some View {
        switch family {
        case .systemMedium:
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 3).fill(meeting.tint).frame(width: 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        GooglyIcon(mood: entry.mood, height: 16).foregroundStyle(iconTint(meeting))
                        Text("NOW · ENDS IN").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                    }
                    CountdownText(target: meeting.end)
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(.white)
                    Text(meeting.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(thenText ?? "Until \(meeting.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if meeting.hasLink {
                    Link(destination: meeting.joinURL) {
                        VStack(spacing: 2) {
                            Image(systemName: "video.fill").font(.title3)
                            Text("Join").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(meeting.tint, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    GooglyIcon(mood: entry.mood, height: 12)
                    Text("Now · ends in").font(.caption.weight(.semibold))
                    CountdownText(target: meeting.end).font(.caption.weight(.semibold)).monospacedDigit()
                }
                Text(meeting.title).font(.headline).lineLimit(1).widgetAccentable()
                Text(thenText ?? "Until \(meeting.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text("NOW").font(.system(size: 8, weight: .bold))
                    CountdownText(target: meeting.end, showsHours: false)
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .multilineTextAlignment(.center).minimumScaleFactor(0.5).lineLimit(1)
                        .padding(.horizontal, 4)
                }
            }
            .accessibilityLabel("\(meeting.title), in progress")
        case .accessoryInline:
            Text("\(meeting.title) · \(Text(timerInterval: entry.date...max(entry.date, meeting.end), countsDown: true)) left")
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    GooglyIcon(mood: entry.mood, height: 18).foregroundStyle(iconTint(meeting))
                    Spacer(minLength: 0)
                    Text(meeting.start, style: .time).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                Text("NOW · ENDS IN").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                CountdownText(target: meeting.end)
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .foregroundStyle(.white)
                Text(meeting.title).font(.subheadline.weight(.semibold)).foregroundStyle(meeting.tint).lineLimit(2)
            }
        }
    }
}

private struct DoneText: View {
    let unknown: Bool
    var body: some View { Text(unknown ? "Open Cadence to see meetings" : doneText) }
}

/// Counts down to `target` with the system timer; "Now" once it's reached.
private struct CountdownText: View {
    let target: Date
    var showsHours = true

    var body: some View {
        if target > Date() {
            Text(timerInterval: Date()...target, countsDown: true, showsHours: showsHours)
        } else {
            Text("Now")
        }
    }
}

// MARK: - Colour

private extension WidgetMeeting {
    var tint: Color { Color(red: red, green: green, blue: blue) }
}

/// The icon's colour on the dark widget: the next meeting's calendar, lifted when too dark to see.
private func iconTint(_ m: WidgetMeeting?) -> Color {
    guard let m else { return .white }
    var (r, g, b) = (m.red, m.green, m.blue)
    let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    if luminance < 0.4 {
        let lift = (0.4 - luminance) / 0.4 * 0.5
        (r, g, b) = (r + (1 - r) * lift, g + (1 - g) * lift, b + (1 - b) * lift)
    }
    return Color(red: r, green: g, blue: b)
}

// MARK: - Day moments

/// Focus time, a break, before or after work: the mascot in its pose and what's going on.
private struct MomentWidgetView: View {
    let segment: WidgetSegment
    let family: WidgetFamily
    let date: Date

    var body: some View {
        switch family {
        case .systemMedium:
            HStack(spacing: 16) {
                GooglyMascot(pose: segment.pose, height: 70, animated: false).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 3) {
                    Text(segment.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    if segment.countsDown {
                        CountdownText(target: segment.end)
                            .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(segment.pose.propColor)
                    }
                    Text(segment.detail).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    GooglyMascot(pose: segment.pose, height: 13, animated: false)
                    Text(segment.title).font(.caption.weight(.semibold)).lineLimit(1)
                }
                if segment.countsDown {
                    CountdownText(target: segment.end).font(.headline).monospacedDigit().widgetAccentable()
                }
                Text(segment.detail).font(.caption).foregroundStyle(.secondary).lineLimit(segment.countsDown ? 1 : 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    GooglyMascot(pose: segment.pose, height: 14, animated: false)
                    if segment.countsDown {
                        CountdownText(target: segment.end, showsHours: false)
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.5).lineLimit(1).padding(.horizontal, 4)
                    }
                }
            }
            .accessibilityLabel(segment.title)
        case .accessoryInline:
            if segment.countsDown {
                Text("\(segment.title) · \(Text(timerInterval: date...max(date, segment.end), countsDown: true)) left")
            } else {
                Text(segment.title)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                GooglyMascot(pose: segment.pose, height: 46, animated: false).foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(segment.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                if segment.countsDown {
                    CountdownText(target: segment.end)
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .foregroundStyle(segment.pose.propColor)
                } else {
                    Text(segment.detail).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
