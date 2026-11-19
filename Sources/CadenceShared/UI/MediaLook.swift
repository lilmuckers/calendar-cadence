import CadenceCore
import SwiftUI

// Shared by the iPhone's desk media card and the Mac's mini-player.

// MARK: - Look

struct MediaTheme {
    var accent: Color
    var background: AnyShapeStyle
    var foreground: Color = .white
    var secondary: Color = .white.opacity(0.7)
    /// The big play/pause sits on a filled accent circle.
    var accentFill = true
    var onAccent: Color = .black
}

extension MediaApp {
    var theme: MediaTheme {
        switch self {
        case .appleMusic:
            MediaTheme(accent: .white,
                       background: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFA2D48), Color(hex: 0xB0122E)], startPoint: .topLeading, endPoint: .bottomTrailing)),
                       secondary: .white.opacity(0.8), onAccent: Color(hex: 0xFA2D48))
        case .spotify:
            MediaTheme(accent: Color(hex: 0x1DB954), background: AnyShapeStyle(Color(hex: 0x181818)), secondary: Color(hex: 0xB3B3B3))
        case .youTubeMusic:
            MediaTheme(accent: Color(hex: 0xFF0033), background: AnyShapeStyle(Color(hex: 0x0F0F0F)), secondary: .white.opacity(0.65), onAccent: .white)
        case .podcasts:
            MediaTheme(accent: .white,
                       background: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xC160F6), Color(hex: 0x7B2FD6)], startPoint: .topLeading, endPoint: .bottomTrailing)),
                       secondary: .white.opacity(0.8), onAccent: Color(hex: 0x8A3FE0))
        }
    }
}

/// A simple drawn mark for each player (their real icons aren't available to other apps).
struct MediaLogo: View {
    let app: MediaApp
    var size: CGFloat

    var body: some View {
        ZStack {
            switch app {
            case .appleMusic:
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xFB5C74), Color(hex: 0xFA233B)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "music.note").font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white)
            case .spotify:
                Circle().fill(Color(hex: 0x1DB954))
                SpotifyWaves().stroke(.black, style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                    .frame(width: size * 0.56, height: size * 0.42)
            case .youTubeMusic:
                Circle().fill(Color(hex: 0xFF0033))
                Circle().strokeBorder(.white, lineWidth: max(1, size * 0.05)).padding(size * 0.2)
                Image(systemName: "play.fill").font(.system(size: size * 0.24)).foregroundStyle(.white).offset(x: size * 0.02)
            case .podcasts:
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xD56DFB), Color(hex: 0x832BC1)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Three arcs, widest on top.
private struct SpotifyWaves: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let rows: [(y: CGFloat, inset: CGFloat, bow: CGFloat)] = [(0.12, 0, 0.16), (0.5, 0.08, 0.12), (0.86, 0.16, 0.09)]
        for row in rows {
            let y = r.minY + r.height * row.y
            let x0 = r.minX + r.width * row.inset, x1 = r.maxX - r.width * row.inset
            p.move(to: CGPoint(x: x0, y: y + r.height * row.bow))
            p.addQuadCurve(to: CGPoint(x: x1, y: y + r.height * row.bow * 1.3),
                           control: CGPoint(x: r.midX, y: y - r.height * row.bow))
        }
        return p
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
