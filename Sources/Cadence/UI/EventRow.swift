import CadenceCore
import SwiftUI

/// One agenda line: colour bar, time, title, metadata, Join; expands to show map/notes.
struct EventRow: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var isPast: Bool { meeting.end <= state.now }
    private var isLive: Bool { meeting.isInProgress(at: state.now) }
    private var canExpand: Bool { meeting.physicalLocation != nil || notes != nil || meeting.organizer != nil }
    private var notes: String? {
        guard let n = meeting.notes else { return nil }
        let text = MeetingLinkDetector.plainText(n)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(meeting.tint.gradient)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.isAllDay ? "All day" : Theme.time(meeting.start))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if !meeting.isAllDay {
                        Text(Theme.time(meeting.end))
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 58, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(meeting.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(expanded ? 3 : 1)
                        if isLive { LiveBadge(color: meeting.tint) }
                        if state.clashes.contains(where: { $0.meetings.contains { $0.id == meeting.id } }) {
                            Image(systemName: state.suppressedByClash.contains(meeting.id) ? "bell.slash.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .help(state.suppressedByClash.contains(meeting.id)
                                      ? "Clash — you chose not to be alerted for this one. Right-click → Clash Alerts to change."
                                      : "Overlaps another meeting. Right-click → Clash Alerts to choose which one alerts.")
                        }
                        if case let attached = state.enrichments(for: meeting), !attached.isEmpty {
                            Button { state.onShowEnrichments?(meeting) } label: {
                                Label("\(attached.count)", systemImage: "paperclip")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(meeting.tint)
                            }
                            .buttonStyle(.plain)
                            .help("Attached by an assistant: " + attached.map(\.title).joined(separator: ", "))
                        }
                        if state.isAgendaOnly(meeting) {
                            Image(systemName: "bell.slash")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .help("Agenda only — this calendar never alerts or clashes")
                        }
                        if state.isHiddenFromPanel(meeting) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .help("Hidden from the countdown panel")
                        }
                        if meeting.participation == .tentative || meeting.participation == .pending {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .help(meeting.participation == .pending ? "Not responded" : "Tentative")
                        }
                    }
                    metadata
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 6) {
                    if !isPast { JoinButton(meeting: meeting, size: .small) }
                    if canExpand {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .onTapGesture { if canExpand { toggle() } }

            if let save = state.saveStates[meeting.id] {
                SaveIndicator(state: save, tint: meeting.tint)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            } else if isLive {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(meeting.tint.opacity(0.18))
                        Capsule().fill(meeting.tint.gradient).frame(width: max(4, geo.size.width * progress))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            if expanded {
                EventDetail(meeting: meeting, notes: notes)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(background)
        )
        .saveFlash(state.saveStates[meeting.id], tint: meeting.tint)
        .animation(.easeOut(duration: 0.25), value: meeting.eventColor)
        .opacity(isPast && !expanded ? 0.45 : 1)
        .onHover { hovering = $0 }
        .contextMenu {
            EventActionsMenu(meeting: meeting)
            if meeting.joinLink != nil {
                Button("Join") { state.join(meeting) }
                JoinInMenu(meeting: meeting)
            }
            if let link = meeting.joinLink {
                Button("Copy Meeting Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                }
            }
            Button("Show in Calendar") { state.openInCalendar(meeting) }
            if !state.enrichments(for: meeting).isEmpty {
                Button("Show Attached Notes…") { state.onShowEnrichments?(meeting) }
            }
            if !meeting.isAllDay {
                Divider()
                RunningLateMenu(meeting: meeting)
                ClashAlertsMenu(meeting: meeting)
                PanelVisibilityMenu(meeting: meeting)
            }
        }
    }

    private var background: Color {
        if isLive { return meeting.tint.opacity(0.12) }
        if expanded || hovering { return .primary.opacity(0.05) }
        return .clear
    }

    private var progress: Double {
        guard meeting.duration > 0 else { return 0 }
        return min(1, max(0, state.now.timeIntervalSince(meeting.start) / meeting.duration))
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(meeting.calendar.title)
                .foregroundStyle(Color(meeting.calendar.color))
            if let service = meeting.joinLink?.service {
                dot
                Label(service.displayName, systemImage: service.symbol).labelStyle(.titleOnly)
            } else if let loc = meeting.physicalLocation {
                dot
                Label(loc, systemImage: "mappin").labelStyle(.titleAndIcon).lineLimit(1)
            }
            if meeting.attendeeCount > 1 {
                dot
                Label("\(meeting.attendeeCount)", systemImage: "person.2.fill").labelStyle(.titleAndIcon)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var dot: some View {
        Text("·").foregroundStyle(.tertiary)
    }
}

private struct LiveBadge: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
                .opacity(pulse ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
            Text("NOW").font(.system(size: 9, weight: .bold)).tracking(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .onAppear { pulse = true }
    }
}

/// Expanded section: map + travel time for physical locations, organiser, notes.
private struct EventDetail: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    let notes: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let location = meeting.physicalLocation {
                LocationDetail(query: location, tint: meeting.tint, start: meeting.start)
            }
            if let organizer = meeting.organizer {
                Label("Organised by \(organizer)", systemImage: "person.crop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let notes {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.04)))
            }
        }
        .padding(.leading, 14)
    }
}

/// Context-menu items to keep a meeting (or its whole series) off the countdown panel.
struct PanelVisibilityMenu: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting

    var body: some View {
        if state.isHiddenFromPanel(meeting) {
            Button("Show in Countdown Panel") { state.showInPanel(meeting) }
        } else if state.isRecurring(meeting) {
            Menu("Hide from Countdown Panel") {
                Button("This Event") { state.hideFromPanel(meeting, series: false) }
                Button("All Occurrences") { state.hideFromPanel(meeting, series: true) }
            }
        } else {
            Button("Hide from Countdown Panel") { state.hideFromPanel(meeting, series: false) }
        }
        let quiet = state.isCalendarAgendaOnly(meeting.calendar.id)
        Button(quiet ? "Alert for “\(meeting.calendar.title)” Again" : "Make “\(meeting.calendar.title)” Agenda Only") {
            state.setCalendar(meeting.calendar.id, agendaOnly: !quiet)
        }
    }
}

/// "Clash Alerts ▸" — change or undo the choice made in the clash prompt.
struct ClashAlertsMenu: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting

    var body: some View {
        ForEach(state.clashes(involving: meeting), id: \.key) { clash in
            let choice = state.clashChoice(clash)
            let others = clash.meetings.filter { $0.id != meeting.id }
            Menu(others.count == 1 ? "Clash Alerts (with \(others[0].title))" : "Clash Alerts") {
                ForEach(clash.meetings) { m in
                    item(m.id == meeting.id ? "Alert for This One Only" : "Alert for “\(m.title)” Only",
                         checked: choice == m.id) { state.resolveClash(clash, choice: m.id) }
                }
                item("Alert for All of Them", checked: choice == "all") { state.resolveClash(clash, choice: "all") }
                Divider()
                Button("Ask Again…") { state.askAgain(clash) }
            }
        }
    }

    @ViewBuilder private func item(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
