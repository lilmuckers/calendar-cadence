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
/// sends volume keys anyway.
@MainActor
@Observable
final class PhoneVolume {
    /// 0...1, as the system reports it.
    private(set) var level: Double = Double(AVAudioSession.sharedInstance().outputVolume)
    /// Cadence muted it (the phone has no media mute of its own): `level` is 0 and `restore` comes back on unmute.
    private(set) var muted = false
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
            break
        }
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

/// Puts the (invisible) volume view in the desk display's window so `PhoneVolume` can drive it.
/// Having one on screen also keeps iOS's own volume overlay from covering the desk display.
struct PhoneVolumeHost: UIViewRepresentable {
    let volume: PhoneVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.011
        view.isUserInteractionEnabled = false
        view.showsRouteButton = false
        volume.view = view
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        volume.view = view
    }
}
