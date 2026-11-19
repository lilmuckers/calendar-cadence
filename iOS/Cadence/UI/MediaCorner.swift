import CadenceCore
import SwiftUI

/// Bottom-right of the landscape desk display: now-playing controls while something's playing on
/// this phone (or, when connected, on the Mac), otherwise a small button that opens the preferred
/// media app. Everything wears the player's colours.
struct MediaCorner: View {
    @Environment(PhoneState.self) private var state
    /// Height of the card, so the desk can keep room for it.
    static let height: CGFloat = 64

    var body: some View {
        let np = state.nowPlaying
        let app = state.prefs.mediaApp
        let mode = self.mode
        Group {
            switch mode {
            case .phone:
                MediaCard(model: phoneModel).transition(.move(edge: .trailing).combined(with: .opacity))
            case .mac(let media):
                MediaCard(model: macModel(media)).transition(.move(edge: .trailing).combined(with: .opacity))
            case .launcher:
                Button { state.openMediaApp() } label: {
                    MediaLogo(app: app, size: 44)
                        .shadow(color: app.theme.accent.opacity(0.35), radius: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(app.name)")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(Theme.spring, value: mode.key)
        // Only ask for Music access when it's the chosen app (it's the only one that shares its track).
        .onAppear { np.start(prompt: app == .appleMusic) }
        .onChange(of: app) { _, new in np.start(prompt: new == .appleMusic) }
    }

    private enum Mode {
        case phone, mac(CompanionMedia), launcher
        var key: String {
            switch self {
            case .phone: "phone"
            case .mac: "mac"
            case .launcher: "launcher"
            }
        }
    }

    /// This phone's audio wins (it's what's in your ears from here); then the Mac's.
    private var mode: Mode {
        if state.nowPlaying.showsControls(now: state.now) { return .phone }
        if let mac = state.macMedia { return .mac(mac) }
        return .launcher
    }

    private var phoneModel: MediaCardModel {
        let np = state.nowPlaying
        // Apple Music's look when it's the Music app (we know the track), else the preferred app.
        let music = np.musicPlaying || (np.hasTrack && !np.otherPlaying)
        let app = music ? .appleMusic : state.prefs.mediaApp
        if music {
            return MediaCardModel(
                app: app, title: np.title ?? app.name, subtitle: np.artist ?? app.name, artwork: np.artwork,
                isPlaying: np.musicPlaying, canSkip: true,
                playPause: { np.musicPlaying ? np.pauseMusic() : np.resumeMusic() },
                next: { np.next() }, previous: { np.previous() }, open: nil)
        }
        // Other apps can be stopped from here but only started again in the app itself.
        return MediaCardModel(
            app: app, title: np.otherPlaying ? "Playing on this iPhone" : "Paused", subtitle: app.name, artwork: nil,
            isPlaying: np.otherPlaying, canSkip: false,
            playPause: np.otherPlaying ? { state.pauseMedia() } : nil,
            next: nil, previous: nil, open: { state.openMediaApp() })
    }

    private func macModel(_ media: CompanionMedia) -> MediaCardModel {
        let mac = state.link.mac?.displayName ?? "Mac"
        return MediaCardModel(
            app: media.app, title: media.title ?? "Playing on \(mac)",
            subtitle: [media.artist, "on \(mac)"].compactMap { $0 }.joined(separator: " · "),
            artwork: state.macArtwork, isPlaying: media.isPlaying, canSkip: media.canSkip,
            playPause: { state.controlMac(.togglePlayPause) },
            next: { state.controlMac(.next) }, previous: { state.controlMac(.previous) }, open: nil,
            badge: "laptopcomputer")
    }
}

struct MediaCardModel {
    var app: MediaApp
    var title: String
    var subtitle: String
    var artwork: UIImage?
    var isPlaying: Bool
    var canSkip: Bool
    var playPause: (() -> Void)?
    var next: (() -> Void)?
    var previous: (() -> Void)?
    var open: (() -> Void)?
    /// SF Symbol shown by the title when the player is on another device.
    var badge: String?
}

private struct MediaCard: View {
    let model: MediaCardModel

    var body: some View {
        let app = model.app
        let theme = app.theme
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if let badge = model.badge { Image(systemName: badge).font(.caption2) }
                    Text(model.subtitle).lineLimit(1)
                }
                .font(.caption).foregroundStyle(theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                if model.canSkip, let previous = model.previous { control("backward.fill", "Previous", action: previous) }
                if let playPause = model.playPause {
                    control(model.isPlaying ? "pause.fill" : "play.fill", model.isPlaying ? "Pause" : "Play", big: true, action: playPause)
                }
                if model.canSkip, let next = model.next { control("forward.fill", "Next", action: next) }
                if let open = model.open { control("arrow.up.forward.app.fill", "Open \(app.name)", action: open) }
            }
        }
        .foregroundStyle(theme.foreground)
        .padding(10)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            MediaLogo(app: app, size: 16).offset(x: 5, y: -5)
        }
        .frame(maxWidth: 360)
    }

    @ViewBuilder private var artwork: some View {
        if let image = model.artwork {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            MediaLogo(app: model.app, size: 44)
        }
    }

    private func control(_ symbol: String, _ label: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        let theme = model.app.theme
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 18 : 14, weight: .bold))
                .frame(width: big ? 40 : 32, height: 40)
                .background(big && theme.accentFill ? theme.accent : .clear, in: Circle())
                .foregroundStyle(big && theme.accentFill ? theme.onAccent : theme.foreground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

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
