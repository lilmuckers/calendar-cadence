import AppKit
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
    static let corner: CGFloat = 14
    static let rowCorner: CGFloat = 10
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Today 14:00", "Tomorrow 09:30", "Thu 20 Nov 10:00".
    static func dayTime(_ date: Date) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(date) ? "today" : cal.isDateInTomorrow(date) ? "tomorrow"
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(day) \(time(date))"
    }

        static func range(_ m: Meeting) -> String {
        m.isAllDay ? "All day" : "\(time(m.start)) – \(time(m.end))"
    }
}

/// Glass background. Uses real behind-window blur, or a flat tint when rendering screenshots
/// (offscreen renders can't capture window-server blur).
struct VisualEffect: View {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    /// Set by the screenshot renderer.
    static var screenshotFill: Color?

    var body: some View {
        if let fill = Self.screenshotFill {
            fill
        } else {
            VisualEffectView(material: material, blending: blending)
        }
    }
}

/// NSVisualEffectView bridge: real behind-window blur, which SwiftUI materials can't do for a whole window.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .active
        v.material = material
        v.blendingMode = blending
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Pill-shaped Join button tinted with the event's calendar colour.
struct JoinButton: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    var size: ControlSize = .regular
    var afterJoin: (() -> Void)? = nil

    var body: some View {
        if let link = meeting.joinLink {
            Button {
                state.join(meeting)
                afterJoin?()
            } label: {
                Label(size == .large ? "Join \(link.service.displayName)" : "Join", systemImage: link.service.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(font)
                    .padding(.horizontal, size == .large ? 26 : 10)
                    .padding(.vertical, size == .large ? 14 : 5)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(meeting.tint.gradient))
                    .shadow(color: meeting.tint.opacity(0.35), radius: size == .large ? 18 : 4, y: 2)
            }
            .buttonStyle(PressableStyle())
            .help(state.joinHint(for: meeting) ?? "Join on \(link.service.displayName)")
        }
    }

    private var font: Font {
        switch size {
        case .large, .extraLarge: .system(size: 20, weight: .semibold, design: .rounded)
        case .small, .mini: .system(size: 11, weight: .semibold, design: .rounded)
        default: .system(size: 12, weight: .semibold, design: .rounded)
        }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet icon button used in toolbars and footers.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Thin line under a row while a reply or colour change saves: a segment sweeps across it,
/// then it fills solid for a moment when the source confirms, and fades away.
struct SaveIndicator: View {
    let state: AppState.SaveState?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                if state == .saving && !reduceMotion {
                    TimelineView(.animation) { ctx in
                        let period = 1.1
                        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let eased = t * t * (3 - 2 * t)
                        let w = max(24, geo.size.width * 0.3)
                        Capsule().fill(tint.gradient)
                            .frame(width: w)
                            .offset(x: -w + (geo.size.width + w) * eased)
                    }
                } else if state == .saving {
                    Capsule().fill(tint.opacity(0.5))
                } else if state == .saved {
                    Capsule().fill(tint.gradient)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .opacity(state == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.3), value: state)
        .accessibilityHidden(state == nil)
        .accessibilityLabel(state == .saving ? "Saving" : "Saved")
    }
}

/// A quick glow over a row when a save lands, then it settles back.
struct SaveFlash: ViewModifier {
    let state: AppState.SaveState?
    let tint: Color
    var cornerRadius: CGFloat = Theme.rowCorner
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(lit ? 0.22 : 0))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(tint.opacity(lit ? 0.8 : 0), lineWidth: 1.5))
                    .allowsHitTesting(false)
            }
            .onChange(of: state) { _, new in
                guard new == .saved else { return }
                withAnimation(.easeOut(duration: 0.12)) { lit = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.7)) { lit = false }
                }
            }
    }
}

extension View {
    func saveFlash(_ state: AppState.SaveState?, tint: Color, cornerRadius: CGFloat = Theme.rowCorner) -> some View {
        modifier(SaveFlash(state: state, tint: tint, cornerRadius: cornerRadius))
    }
}
