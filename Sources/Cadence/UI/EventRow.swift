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

            if isLive {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(meeting.tint)
                    .controlSize(.mini)
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
        .opacity(isPast && !expanded ? 0.45 : 1)
        .onHover { hovering = $0 }
        .contextMenu {
            if meeting.joinLink != nil { Button("Join") { state.join(meeting) } }
            if let link = meeting.joinLink {
                Button("Copy Meeting Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                }
            }
            Button("Show in Calendar") { state.openInCalendar(meeting) }
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
                .foregroundStyle(meeting.tint)
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
