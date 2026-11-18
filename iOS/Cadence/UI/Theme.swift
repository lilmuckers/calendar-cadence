import CadenceCore
import SwiftUI

extension Color {
    init(_ c: RGBAColor) {
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}

extension Meeting {
    var tint: Color { Color(displayColor) }
}

enum Theme {
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func range(_ m: Meeting) -> String {
        m.isAllDay ? "All day" : "\(time(m.start)) – \(time(m.end))"
    }

    /// "Zoom · 6 people", "Room 4", "Work"
    static func detail(_ m: Meeting) -> String {
        var parts: [String] = []
        if let service = m.joinLink?.service.displayName { parts.append(service) } else if let place = m.physicalLocation { parts.append(place) }
        if m.attendeeCount > 1 { parts.append("\(m.attendeeCount) people") }
        if parts.isEmpty { parts.append(m.calendar.title) }
        return parts.joined(separator: " · ")
    }
}

/// Small coloured row used in agendas.
struct MeetingRow: View {
    @Environment(PhoneState.self) private var state
    let meeting: Meeting
    var compact = false

    var body: some View {
        let past = meeting.end <= state.now
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(meeting.tint).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(meeting.title).font(compact ? .subheadline.weight(.semibold) : .headline).lineLimit(1)
                    if meeting.isInProgress(at: state.now) {
                        Text("NOW").font(.caption2.weight(.heavy)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(meeting.tint.opacity(0.3), in: Capsule())
                    }
                }
                Text("\(Theme.range(meeting)) · \(Theme.detail(meeting))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if meeting.joinLink != nil, meeting.end > state.now {
                Button { state.join(meeting) } label: {
                    Image(systemName: meeting.joinLink?.service.symbol ?? "video.fill")
                        .font(compact ? .callout : .body)
                        .frame(width: compact ? 34 : 40, height: compact ? 30 : 34)
                        .background(meeting.tint.opacity(0.25), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Join \(meeting.title)")
            }
        }
        .opacity(past ? 0.45 : 1)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Where Join goes right now, for labels.
struct ConnectionPill: View {
    @Environment(PhoneState.self) private var state

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private var color: Color {
        switch state.link.status {
        case .connected: .green
        case .connecting, .searching: .orange
        case .failed: .red
        case .off, .unpaired: .gray
        }
    }

    private var text: String {
        let mac = state.link.mac?.name ?? "Mac"
        switch state.link.status {
        case .connected: return state.displaying ? "\(mac) · quiet" : mac
        case .connecting: return "Connecting to \(mac)…"
        case .searching: return "Looking for \(mac)…"
        case .failed: return "\(mac) unavailable"
        case .off: return mac
        case .unpaired: return "On this iPhone"
        }
    }
}
