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
                Button { state.launchMedia() } label: {
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
        if state.nowPlaying.showsControls(now: state.now) || state.spotifyActive { return .phone }
        if let mac = state.macMedia { return .mac(mac) }
        return .launcher
    }

    private var phoneModel: MediaCardModel {
        let np = state.nowPlaying
        if state.spotifyActive {
            let sp = state.spotify
            return MediaCardModel(
                app: .spotify, title: sp.title ?? "Spotify", subtitle: sp.artist ?? "Spotify", artwork: sp.artwork,
                isPlaying: sp.isPlaying, canSkip: sp.canSkip,
                playPause: { sp.togglePlay() }, next: { sp.next() }, previous: { sp.previous() }, open: nil)
        }
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
        // Other apps can be stopped from here but only started again in the app itself. Spotify
        // that isn't hooked up yet offers to connect (a quick hop to Spotify to approve).
        let connect = app == .spotify && state.spotify.isAvailable && !state.spotify.connected
        return MediaCardModel(
            app: app, title: np.otherPlaying ? "Playing on this iPhone" : "Paused",
            subtitle: connect ? (state.spotify.lastError ?? "Tap the link to show the track") : app.name, artwork: nil,
            isPlaying: np.otherPlaying, canSkip: false,
            playPause: np.otherPlaying ? { state.pauseMedia() } : nil,
            next: nil, previous: nil,
            open: connect ? { state.spotify.authorize() } : { state.openMediaApp() },
            openSymbol: connect ? "link" : nil)
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
    /// Replaces the open-app icon (e.g. "link" for Connect Spotify).
    var openSymbol: String? = nil
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
                if let open = model.open {
                    control(model.openSymbol ?? "arrow.up.forward.app.fill",
                            model.openSymbol == nil ? "Open \(app.name)" : "Connect \(app.name)", action: open)
                }
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

