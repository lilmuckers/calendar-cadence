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
                Group {
                    if landscape {
                        HStack(spacing: 28) {
                            VStack(alignment: .leading) {
                                header
                                Spacer(minLength: 8)
                                FocusBlock(scale: min(1.2, geo.size.height / 360))
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            AgendaColumn(limit: 8)
                                .frame(width: min(360, geo.size.width * 0.42))
                        }
                        .padding(.horizontal, 28).padding(.vertical, 20)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            Spacer(minLength: 12)
                            FocusBlock(scale: min(1.15, geo.size.width / 360))
                            Spacer(minLength: 12)
                            AgendaColumn(limit: 4)
                        }
                        .padding(.horizontal, 22).padding(.vertical, 16)
                    }
                }
                .opacity(dimmed ? 0.55 : 1)
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

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

    var body: some View {
        if let focus = state.focus {
            let m = focus.meeting
            let remaining = focus.target.timeIntervalSince(state.now)
            VStack(alignment: .leading, spacing: 10 * scale) {
                Text(focus.live ? "ENDS IN" : (Calendar.current.isDate(m.start, inSameDayAs: state.now) ? "UP NEXT" : "TOMORROW"))
                    .font(.system(size: 14 * scale, weight: .heavy)).kerning(1.5)
                    .foregroundStyle(m.tint)
                Text(CountdownFormatter.clock(remaining))
                    .font(.system(size: 96 * scale, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: Int(remaining))
                Text(m.title)
                    .font(.system(size: 30 * scale, weight: .bold))
                    .lineLimit(2).minimumScaleFactor(0.6)
                Label("\(Theme.range(m)) · \(Theme.detail(m))", systemImage: m.joinLink?.service.symbol ?? "calendar")
                    .font(.system(size: 16 * scale)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                if m.joinLink != nil {
                    JoinButton(meeting: m, scale: scale).padding(.top, 8 * scale)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "checkmark.circle").font(.system(size: 54 * scale)).foregroundStyle(.green)
                Text("All clear").font(.system(size: 40 * scale, weight: .bold))
                Text(state.meetings.isEmpty ? "Nothing on the calendar." : "No more meetings today.")
                    .font(.title3).foregroundStyle(.white.opacity(0.6))
            }
        }
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
                Text(state.link.isConnected ? "Join on \(state.link.mac?.name ?? "Mac")" : "Join \(meeting.joinLink?.service.displayName ?? "")")
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
            if let banner = state.banner {
                ReminderBanner(reminder: banner)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A heads-up / wrap-up reminder forwarded from the Mac.
struct ReminderBanner: View {
    @Environment(PhoneState.self) private var state
    let reminder: CompanionReminder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(reminder.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if let id = reminder.joinMeetingID {
                Button("Join") { state.join(id: id); state.banner = nil }.buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onTapGesture { state.banner = nil }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
