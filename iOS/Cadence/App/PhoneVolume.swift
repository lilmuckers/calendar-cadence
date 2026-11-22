import CadenceCore
import MediaPlayer
import SwiftUI
import UIKit

/// The phone's media volume, for the Mac's volume keys (media remote control).
///
/// iOS has no public call to set the system volume. The usual workaround, used here, is the slider
/// inside an `MPVolumeView`: setting it moves the real system volume (what AirPods play at).
/// It isn't a supported API and could stop working in a future iOS. It only works while that view
/// is in a window, i.e. while Cadence's desk display is on screen — which is the only time the Mac
/// sends volume keys anyway. That view is the desk's `VolumePill`, which shows itself whenever a
/// key changes the volume, so the system's own volume control is on screen as it moves.
@MainActor
@Observable
final class PhoneVolume {
    /// 0...1, as the system reports it.
    private(set) var level: Double = Double(AVAudioSession.sharedInstance().outputVolume)
    /// Cadence muted it (the phone has no media mute of its own): `level` is 0 and `restore` comes back on unmute.
    private(set) var muted = false
    /// When a Mac volume key last arrived, so the pill can show for a moment.
    private(set) var changedAt: Date?
    #if DEBUG
    /// `-previewVolume`: keep the pill up, for checking the layout.
    let pinned = ProcessInfo.processInfo.arguments.contains("-previewVolume")
    #else
    let pinned = false
    #endif
    @ObservationIgnored private var restore: Double?
    @ObservationIgnored fileprivate weak var view: MPVolumeView?

    private var slider: UISlider? {
        view?.subviews.lazy.compactMap { $0 as? UISlider }.first
    }

    /// The current level, re-read (the hardware buttons and Control Center change it too).
    func poll() {
        guard let slider else { return }
        let now = Double(slider.value)
        if abs(now - level) > 0.001 {
            level = now
            // Turned up by hand while "muted": it isn't any more.
            if muted && now > 0 { muted = false; restore = nil }
        }
    }

    func apply(_ command: MediaCommand) {
        poll()
        switch command {
        case .volumeUp:
            if muted { unmute() } else { set(MediaVolume.stepped(level, up: true)) }
        case .volumeDown:
            if !muted { set(MediaVolume.stepped(level, up: false)) }
        case .toggleMute:
            if muted { unmute() } else if level > 0 {
                restore = level
                set(0)
                muted = true
            }
        default:
            return
        }
        changedAt = Date()
    }

    private func unmute() {
        muted = false
        set(restore ?? MediaVolume.step * 4)
        restore = nil
    }

    private func set(_ value: Double) {
        level = value
        guard let slider else { return }
        slider.setValue(Float(value), animated: false)
        slider.sendActions(for: .valueChanged)
    }
}

/// A small glass pill with the system volume slider, on the desk display. It appears for a moment
/// when the Mac's keys change the volume and can be dragged while it's up; the rest of the time it's
/// all but transparent (a fully hidden `MPVolumeView` stops working), so the desk looks as before.
/// Having it on screen also keeps iOS's own volume overlay from covering the desk.
struct VolumePill: View {
    let volume: PhoneVolume
    /// How long it stays up after the last key press.
    private static let linger: Duration = .milliseconds(1600)
    @State private var shown = false

    var body: some View {
        let visible = shown || volume.pinned
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)
                .contentTransition(.symbolEffect(.replace))
            PhoneVolumeHost(volume: volume, visible: visible)
                .frame(width: 140, height: 22)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial.opacity(visible ? 1 : 0), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(visible ? 0.15 : 0), lineWidth: 1))
        .foregroundStyle(.white.opacity(visible ? 0.9 : 0))
        .scaleEffect(visible ? 1 : 0.92)
        .allowsHitTesting(visible)
        .animation(Theme.spring, value: visible)
        .accessibilityHidden(!visible)
        .task(id: volume.changedAt) {
            guard volume.changedAt != nil else { return }
            shown = true
            try? await Task.sleep(for: Self.linger)
            if !Task.isCancelled { shown = false }
        }
    }

    private var symbol: String {
        if volume.muted || volume.level <= 0.001 { return "speaker.slash.fill" }
        return volume.level < 0.34 ? "speaker.wave.1.fill" : volume.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// The `MPVolumeView` that `PhoneVolume` drives, styled to sit in `VolumePill`.
struct PhoneVolumeHost: UIViewRepresentable {
    let volume: PhoneVolume
    var visible: Bool

    /// Hidden, it keeps just enough alpha to stay "on screen" for iOS.
    private static let hiddenAlpha: CGFloat = 0.011

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 140, height: 22))
        view.alpha = Self.hiddenAlpha
        view.showsRouteButton = false
        view.tintColor = .white
        view.setVolumeThumbImage(Self.thumb, for: .normal)
        volume.view = view
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        volume.view = view
        view.isUserInteractionEnabled = visible
        let alpha = visible ? 1 : Self.hiddenAlpha
        guard view.alpha != alpha else { return }
        UIView.animate(withDuration: 0.25) { view.alpha = alpha }
    }

    /// A small white dot instead of the default large thumb, to keep the pill slim.
    private static let thumb: UIImage = {
        let size = CGSize(width: 12, height: 12)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }()
}
