import CadenceCore
import SwiftUI

/// The always-on desk display: big countdown to the next meeting, Join, and what's after it.
/// Portrait stacks everything; landscape puts the countdown left and the agenda right.
struct DeskView: View {
    @Environment(PhoneState.self) private var state
    @Environment(\.verticalSizeClass) private var vSize
    var exit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                background
                // Lets the Mac's volume keys set this phone's volume (invisible).
                PhoneVolumeHost(volume: state.volume).frame(width: 1, height: 1).allowsHitTesting(false)
                Group {
                    if landscape {
                        HStack(spacing: 28) {
                            VStack(alignment: .leading, spacing: 0) {
                                header.layoutPriority(2)
                                Spacer(minLength: 8)
                                // Fills the rest of the side, with Join pinned to the bottom.
                                FocusBlock(scale: min(1.2, geo.size.height / 360), pinsJoin: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Pop-ups sit under the agenda, so the countdown keeps the whole left side.
                            VStack(alignment: .leading, spacing: 12) {
                                if dayDone && !prompting {
                                    // Same header gap and centring as "All clear" on the left, so the two
                                    // line up; small enough to clear the media corner below.
                                    VStack(spacing: 0) {
                                        header.hidden().accessibilityHidden(true)
                                        Spacer(minLength: 8)
                                        DayDone(scale: min(1.2, geo.size.height / 360), art: 100)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                } else {
                                    AgendaColumn(limit: prompting ? 2 : (state.prefs.deskMediaControls ? 6 : 8))
                                    Spacer(minLength: 0)
                                }
                                PromptStrip(style: .panel)
                                // Room for the media corner, drawn above the dimming below.
                                if state.prefs.deskMediaControls { Color.clear.frame(height: MediaCorner.height) }
                            }
                            .frame(width: min(360, geo.size.width * 0.42))
                        }
                        .padding(.horizontal, 28).padding(.vertical, 20)
                    } else {
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                header
                                Spacer(minLength: 12)
                                FocusBlock(scale: min(1.15, geo.size.width / 360))
                                Spacer(minLength: 12)
                                if dayDone {
                                    // Where the agenda would be: the icon, off duty.
                                    DayDone(scale: min(1.15, geo.size.width / 360) * (prompting ? 0.6 : 1))
                                        .frame(maxWidth: .infinity)
                                    Spacer(minLength: 12)
                                } else {
                                    AgendaColumn(limit: prompting ? 2 : 4)
                                }
                            }
                            .padding(.horizontal, 22).padding(.vertical, 16)
                            // The lower third: full width along the bottom edge.
                            PromptStrip(style: .strip)
                        }
                    }
                }
                // A pop-up wakes it: nothing dims while one is up.
                .opacity(dimmed && !prompting ? 0.55 : 1)
                // Bottom right, landscape only; dims with the rest of the desk.
                if landscape && state.prefs.deskMediaControls {
                    MediaCorner()
                        .frame(width: min(360, geo.size.width * 0.42))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.horizontal, 28).padding(.vertical, 20)
                        .opacity(dimmed && !prompting ? 0.55 : 1)
                }
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var prompting: Bool { state.currentPrompt != nil }

    /// Nothing left today: no meeting on now and none to come (`focus` only looks at today).
    private var dayDone: Bool { state.focus == nil }

    /// Between meetings with nothing close, fade back so it's not a bright slab on the desk.
    private var dimmed: Bool {
        guard state.prefs.deskDimWhenIdle else { return false }
        guard let f = state.focus else { return true }
        return !f.live && f.meeting.start.timeIntervalSince(state.now) > 30 * 60
    }

    private var background: some View {
        let tint = state.focus?.meeting.tint ?? .gray
        return ZStack {
            Color.black
            RadialGradient(colors: [tint.opacity(dimmed ? 0.12 : 0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1), value: state.focus?.meeting.id)
    }

    private var header: some View {
        HStack {
            Text(state.now.formatted(date: .omitted, time: .shortened))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(state.now.formatted(.dateTime.weekday(.wide).day().month()))
                .font(.subheadline).foregroundStyle(.white.opacity(0.55))
            Spacer()
            ConnectionPill()
            Button(action: exit) {
                Image(systemName: "xmark").font(.caption.weight(.bold))
                    .frame(width: 28, height: 28).background(.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("Leave desk mode")
        }
    }
}

/// The countdown, title and Join for the focused meeting.
private struct FocusBlock: View {
    @Environment(PhoneState.self) private var state
    var scale: CGFloat
    /// Landscape: take the full height, centre the countdown and keep Join on the bottom edge, so a
    /// long title shrinks instead of pushing the button off the screen.
    var pinsJoin = false

    var body: some View {
        if let focus = state.focus {
            let m = focus.meeting
            if pinsJoin {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    details(focus)
                    Spacer(minLength: 12 * scale)
                    if m.joinLink != nil {
                        JoinButton(meeting: m, scale: scale).fixedSize().layoutPriority(3)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10 * scale) {
                    details(focus)
                    if m.joinLink != nil {
                        JoinButton(meeting: m, scale: scale).padding(.top, 8 * scale)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("All clear").font(.system(size: 40 * scale, weight: .bold))
                Text(state.meetings.isEmpty ? "Nothing on the calendar." : "That's everything for today.")
                    .font(.title3).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxHeight: pinsJoin ? .infinity : nil)
        }
    }

    /// Kicker, countdown, title and time. When space is short the title gives way first (down to one
    /// smaller line), then the countdown shrinks; the kicker and time line keep their size.
    private func details(_ focus: PanelFocus) -> some View {
        let m = focus.meeting
        let remaining = focus.target.timeIntervalSince(state.now)
        return VStack(alignment: .leading, spacing: 10 * scale) {
            Text(focus.live ? "ENDS IN" : (Calendar.current.isDate(m.start, inSameDayAs: state.now) ? "UP NEXT" : "TOMORROW"))
                .font(.system(size: 14 * scale, weight: .heavy)).kerning(1.5)
                .foregroundStyle(m.tint)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
            Text(CountdownFormatter.clock(remaining))
                .font(.system(size: 96 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .contentTransition(.numericText(countsDown: true))
                .animation(.default, value: Int(remaining))
                .layoutPriority(1)
            Text(m.title)
                .font(.system(size: 30 * scale, weight: .bold))
                .lineLimit(2).minimumScaleFactor(0.55)
                .truncationMode(.tail)
            Label("\(Theme.range(m)) · \(Theme.detail(m))", systemImage: m.joinLink?.service.symbol ?? "calendar")
                .font(.system(size: 16 * scale)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        }
    }
}

/// The day's done: the icon with its feet up and a cup of tea, where the agenda would be.
private struct DayDone: View {
    var scale: CGFloat
    /// The drawing's height at scale 1.
    var art: CGFloat = 120

    var body: some View {
        VStack(spacing: 14 * scale) {
            // Solid colours, faded as one, so overlapping strokes don't show through each other.
            GooglyTeaBreak(height: art * scale)
                .foregroundStyle(.white)
                .opacity(0.9)
            VStack(spacing: 4) {
                Text("No more meetings today")
                    .font(.system(size: 20 * scale, weight: .semibold, design: .rounded))
                Text("Time for a nice cup of tea.")
                    .font(.system(size: 15 * scale)).foregroundStyle(.white.opacity(0.55))
            }
            .multilineTextAlignment(.center)
            .lineLimit(2).minimumScaleFactor(0.7)
        }
        .padding(.vertical, 8)
    }
}

struct JoinButton: View {
    @Environment(PhoneState.self) private var state
    let meeting: Meeting
    var scale: CGFloat = 1

    var body: some View {
        Button { state.join(meeting) } label: {
            HStack(spacing: 10) {
                Image(systemName: meeting.joinLink?.service.symbol ?? "video.fill")
                Text(state.link.isConnected ? "Join on \(state.link.mac?.displayName ?? "Mac")" : "Join \(meeting.joinLink?.service.displayName ?? "")")
                    .lineLimit(1)
            }
            .font(.system(size: 20 * scale, weight: .semibold))
            .padding(.horizontal, 26 * scale).padding(.vertical, 14 * scale)
            .background(meeting.tint.gradient, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

/// "Later today" list.
private struct AgendaColumn: View {
    @Environment(PhoneState.self) private var state
    var limit: Int

    var body: some View {
        let later = Array(state.laterToday.prefix(limit))
        VStack(alignment: .leading, spacing: 10) {
            if !later.isEmpty {
                Text("LATER TODAY").font(.caption.weight(.heavy)).kerning(1.2).foregroundStyle(.white.opacity(0.5))
                ForEach(later) { MeetingRow(meeting: $0, compact: true) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
