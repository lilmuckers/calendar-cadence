import CadenceCore
import SwiftUI

/// A small mark showing where a calendar comes from: Google, Microsoft, iCloud, an ICS feed…
struct CalendarKindBadge: View {
    let kind: CalendarKind
    var size: CGFloat = 16
    /// Round letter marks, for sitting inside a circular badge.
    var circular = false

    var body: some View {
        mark
            .frame(width: size, height: size)
            .help(kind.label)
            .accessibilityLabel(kind.label)
    }

    @ViewBuilder private var mark: some View {
        switch kind {
        case .google, .googleViaMac:
            ZStack(alignment: .bottomTrailing) {
                letter("G", Color(red: 0.26, green: 0.52, blue: 0.96))
                if kind == .googleViaMac { viaMac }
            }
        case .microsoft, .exchange:
            ZStack(alignment: .bottomTrailing) {
                windowsSquares
                if kind == .exchange { viaMac }
            }
        case .ics:
            symbol("dot.radiowaves.up.forward", .orange)
        case .subscribed:
            symbol("dot.radiowaves.up.forward", .secondary)
        case .iCloud:
            symbol("icloud.fill", Color(red: 0.25, green: 0.6, blue: 1))
        case .calDAV:
            symbol("server.rack", .secondary)
        case .birthdays:
            symbol("gift.fill", .pink)
        case .local:
            symbol("laptopcomputer", .secondary)
        case .other:
            symbol("calendar", .secondary)
        }
    }

    private func letter(_ s: String, _ color: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: circular ? size / 2 : size * 0.25, style: .continuous)
        return shape
            .fill(.white)
            .overlay(shape.strokeBorder(.black.opacity(0.12)))
            .overlay(Text(s).font(.system(size: size * 0.7, weight: .bold, design: .rounded)).foregroundStyle(color))
    }

    /// Four coloured squares, Microsoft-style.
    private var windowsSquares: some View {
        let gap = size * 0.08
        let colors: [Color] = [
            Color(red: 0.95, green: 0.31, blue: 0.13), Color(red: 0.5, green: 0.73, blue: 0.0),
            Color(red: 0.0, green: 0.64, blue: 0.94), Color(red: 1.0, green: 0.73, blue: 0.0),
        ]
        return VStack(spacing: gap) {
            HStack(spacing: gap) { Rectangle().fill(colors[0]); Rectangle().fill(colors[1]) }
            HStack(spacing: gap) { Rectangle().fill(colors[2]); Rectangle().fill(colors[3]) }
        }
        .padding(size * 0.08)
    }

    private func symbol(_ name: String, _ style: some ShapeStyle) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.72, weight: .semibold))
            .foregroundStyle(style)
    }

    /// A tiny Mac badge for accounts that come through macOS Calendar.
    private var viaMac: some View {
        Image(systemName: "applelogo")
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size * 0.5, height: size * 0.5)
            .background(Circle().fill(.black.opacity(0.75)))
            .offset(x: size * 0.18, y: size * 0.18)
    }
}
