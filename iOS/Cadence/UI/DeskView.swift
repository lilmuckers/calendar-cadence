import CadenceCore
import SwiftUI

/// The always-on desk display: big countdown to the next meeting, Join, and what's after it.
/// Portrait stacks everything; landscape puts the countdown left and the agenda right.
struct DeskView: View {
    @Environment(PhoneState.self) private var state
    @Environment(\.verticalSizeClass) private var vSize
    var exit: () -> Void
    @State private var notesOpen = false

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
                            VStack(alignment: .leading) {
                                header
                                Spacer(minLength: 8)
                                FocusBlock(scale: min(1.2, geo.size.height / 360))
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Pop-ups sit under the agenda, so the countdown keeps the whole left side.
                            VStack(alignment: .leading, spacing: 12) {
                                if let m = notesMeeting {
                                    DeskNotes(meeting: m) { close() }
                                        .transition(.move(edge: .trailing).combined(with: .opacity))
                                } else {
                                    AgendaColumn(limit: prompting ? 2 : (state.prefs.deskMediaControls ? 6 : 8))
                                    Spacer(minLength: 0)
                                }
                                PromptStrip(style: .panel)
                                // Room for the media corner, drawn above the dimming below.
                                if state.prefs.deskMediaControls { Color.clear.frame(height: MediaCorner.height) }
                            }
                            .frame(width: notesMeeting != nil ? min(460, geo.size.width * 0.5) : min(360, geo.size.width * 0.42))
                        }
                        .padding(.horizontal, 28).padding(.vertical, 20)
                    } else {
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                header
                                Spacer(minLength: 12)
                                FocusBlock(scale: min(1.15, geo.size.width / 360))
                                Spacer(minLength: 12)
                                AgendaColumn(limit: prompting ? 2 : 4)
                            }
                            .padding(.horizontal, 22).padding(.vertical, 16)
                            // The lower third: full width along the bottom edge.
                            PromptStrip(style: .strip)
                        }
                        .overlay(alignment: .bottom) {
                            // Portrait: the notes slide up over the lower part, under any pop-up.
                            if let m = notesMeeting {
                                DeskNotes(meeting: m) { close() }
                                    .frame(height: geo.size.height * (prompting ? 0.45 : 0.68))
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, prompting ? 150 : 10)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                }
                // A pop-up wakes it: nothing dims while one is up.
                .opacity(dimmed && !prompting && notesMeeting == nil ? 0.55 : 1)
                .animation(Theme.spring, value: notesMeeting?.id)
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
        .onChange(of: autoOpenKey, initial: true) { _, key in
            if key != nil { notesOpen = true }
        }
        .onChange(of: state.deskEnrichmentMeeting?.id) { _, id in
            if id == nil { notesOpen = false }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var prompting: Bool { state.currentPrompt != nil }

    /// The meeting whose notes are showing.
    private var notesMeeting: Meeting? { notesOpen ? state.deskEnrichmentMeeting : nil }

    /// Changes when a meeting with notes goes live, to open them by themselves (if set to).
    private var autoOpenKey: String? {
        guard state.prefs.deskEnrichmentsAutoOpen, let m = state.deskEnrichmentMeeting, m.isInProgress(at: state.now) else { return nil }
        return m.id
    }

    private func close() { withAnimation(Theme.spring) { notesOpen = false } }

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
            if let m = state.deskEnrichmentMeeting, !notesOpen {
                NotesPill(meeting: m) { withAnimation(Theme.spring) { notesOpen = true } }
            }
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

/// "Notes · 3" in the header: opens what an assistant attached to the meeting.
private struct NotesPill: View {
    @Environment(PhoneState.self) private var state
    let meeting: Meeting
    let open: () -> Void

    var body: some View {
        let list = state.enrichments(for: meeting)
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip").font(.caption.weight(.bold))
                Text(list.count == 1 ? list[0].title : "Notes · \(list.count)").lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(meeting.tint.gradient.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show meeting notes")
    }
}

/// The desk's notes card: tabs for everything attached to the meeting.
private struct DeskNotes: View {
    @Environment(PhoneState.self) private var state
    let meeting: Meeting
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.canEditEnrichments ? "ATTACHED" : "ATTACHED · CONNECT TO YOUR MAC TO TICK")
                        .font(.caption2.weight(.heavy)).kerning(1.2).foregroundStyle(meeting.tint)
                    Text(meeting.title).font(.headline).lineLimit(1)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                        .frame(width: 28, height: 28).background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide notes")
            }
            EnrichmentPanel(meeting: meeting, enrichments: state.enrichments(for: meeting),
                            state: { state.enrichmentState($0, meeting) }, now: state.now,
                            interactive: state.canEditEnrichments) { action in
                state.applyEnrichment(action, meetingID: meeting.id)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(shape.fill(Color(white: 0.08)))
        .background(shape.fill(LinearGradient(colors: [meeting.tint.opacity(0.3), .clear], startPoint: .top, endPoint: .center)))
        .overlay(shape.strokeBorder(.white.opacity(0.12)))
        .clipShape(shape)
    }
}
