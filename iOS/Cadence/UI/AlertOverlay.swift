import AudioToolbox
import CadenceCore
import SwiftUI
import UIKit

/// The phone's full-screen "starting now" alert, the twin of the Mac's takeover. Once the meeting has
/// started it escalates the same way (`TakeoverUrgency`): the glow speeds up and widens, the colour
/// turns red, the edges flash and, near full panic, the content shakes. Three minutes late and still
/// ignored, it falls apart like the Mac's (`Meltdown`): letters ping off and pile up at the bottom,
/// and the countdown's characters break off and rattle around a ring, still counting.
struct AlertOverlay: View {
    @Environment(PhoneState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let meeting: Meeting
    @State private var clock = PulseClock()
    @State private var meltdown = MeltdownModel()

    private var remaining: TimeInterval { meeting.start.timeIntervalSince(state.now) }
    private var urgency: TakeoverUrgency { TakeoverUrgency(secondsLate: -remaining) }
    private var headline: String { TakeoverUrgency.headline(remaining: remaining) }
    private var clockText: String {
        remaining > 0 ? CountdownFormatter.clock(remaining) : "-" + CountdownFormatter.clock(-remaining)
    }
    /// Landscape (or any short screen) gets everything smaller so the ring still fits.
    private var scale: Double { verticalSizeClass == .compact ? 0.6 : 0.85 }
    private var ringSize: CGFloat { 260 * scale }

    var body: some View {
        TimelineView(.animation) { context in
            let u = urgency
            let phase = clock.advance(to: context.date, period: reduceMotion ? 2 : u.period)
            let pulse = (1 - cos(phase * 2 * .pi)) / 2
            content(urgency: u, phase: phase, pulse: reduceMotion ? 0.5 : pulse, date: context.date)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        // Each step up in the headline ("YOU'RE LATE" …) taps the wrist, so to speak.
        .onChange(of: headline) { _, _ in
            if remaining < 0 { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
    }

    @ViewBuilder private func content(urgency u: TakeoverUrgency, phase: Double, pulse: Double, date: Date) -> some View {
        let mood = Color(u.color(from: meeting.displayColor))
        let shake = reduceMotion ? 0 : u.shake
        let melting = !reduceMotion && Meltdown.isActive(secondsLate: -remaining)
        let headline = headline
        ZStack {
            Color.black // opaque base, so the agenda underneath never shows through the gradient
            LinearGradient(colors: [mood, mood.opacity(0.55), .black], startPoint: .top, endPoint: .bottom)
            Color.red.opacity(0.22 * u.alarm * pulse)
            GeometryReader { geo in
                let radius = hypot(geo.size.width, geo.size.height) / 2
                Color.clear.overlay {
                    Circle()
                        .fill(RadialGradient(colors: [mood.opacity(0.55 + 0.2 * u.level), .clear], center: .center,
                                             startRadius: 20, endRadius: radius * 0.75))
                        .frame(width: radius * 2, height: radius * 2)
                        .scaleEffect(u.scaleRange.lowerBound + (u.scaleRange.upperBound - u.scaleRange.lowerBound) * pulse)
                        .opacity(remaining <= 10 && remaining > 0 ? 1 : u.glowOpacity)
                }
            }
            .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(Color.red, lineWidth: 40)
                .blur(radius: 28)
                .opacity(u.alarm * pulse)
                .allowsHitTesting(false)

            VStack(spacing: verticalSizeClass == .compact ? 8 : 18) {
                Spacer(minLength: 0)
                if melting {
                    BreakableText(text: headline, idPrefix: "h", style: .heading, broken: meltdown.brokenLetters,
                                  tracking: 2, wordSpacing: 10)
                        .font(GlyphStyle.heading.font(level: u.level, scale: scale + 0.2))
                } else {
                    Text(headline)
                        .font(GlyphStyle.heading.font(level: u.level, scale: scale + 0.2)).kerning(2)
                        .multilineTextAlignment(.center)
                        .opacity(u.level > 0 ? 1 : 0.8)
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: headline)
                }

                countdown(urgency: u, melting: melting, pulse: pulse)

                if melting {
                    BreakableText(text: meeting.title, idPrefix: "t", style: .title, broken: meltdown.brokenLetters,
                                  wordSpacing: 9)
                        .font(GlyphStyle.title.font(level: u.level, scale: scale))
                } else {
                    Text(meeting.title)
                        .font(GlyphStyle.title.font(level: u.level, scale: scale))
                        .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.6)
                }
                Text("\(Theme.range(meeting)) · \(Theme.detail(meeting))")
                    .font(verticalSizeClass == .compact ? .subheadline : .title3).opacity(0.8).multilineTextAlignment(.center)
                Spacer(minLength: 0)
                if meeting.joinLink != nil {
                    JoinButton(meeting: meeting, scale: 1.2 + 0.1 * u.level)
                }
                HStack(spacing: 14) {
                    Button { state.snooze(meeting) } label: {
                        Label("Snooze 1 min", systemImage: "zzz").frame(maxWidth: .infinity)
                    }
                    Button { state.dismissAlert() } label: {
                        Label("Dismiss", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered).tint(.white).controlSize(.large)
                .padding(.top, 6)
            }
            .padding(28)
            .frame(maxWidth: 560)
            .foregroundStyle(.white)
            .offset(x: shake * sin(phase * 2 * .pi * 2.3), y: shake * 0.4 * cos(phase * 2 * .pi * 3.1))
        }
        .overlayPreferenceValue(GlyphAnchorKey.self) { anchors in
            if melting {
                GeometryReader { geo in
                    let _ = tickMeltdown(anchors: anchors, geo: geo, date: date, headline: headline)
                    ForEach(meltdown.falling, id: \.id) { piece in
                        if let glyph = meltdown.fallingGlyph[piece.id] {
                            Text(String(glyph.0))
                                .font(glyph.1.font(level: u.level, scale: glyph.1 == .heading ? scale + 0.2 : scale))
                                .foregroundStyle(.white)
                                .rotationEffect(.radians(piece.angle))
                                .position(x: piece.position.x, y: piece.position.y)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    /// The countdown. During a meltdown it sits in a ring (the "bottle") its broken-off characters rattle around in.
    @ViewBuilder private func countdown(urgency u: TakeoverUrgency, melting: Bool, pulse: Double) -> some View {
        let font = GlyphStyle.countdown.font(level: u.level, scale: scale * GlyphStyle.countdownFit(clockText))
        ZStack {
            Circle().stroke(.white.opacity(melting ? 0.25 : 0), lineWidth: 5)
                .animation(.easeIn(duration: 1.5), value: melting)
            if melting {
                BreakableCountdown(text: clockText, broken: meltdown.brokenSlots).font(font)
                ForEach(meltdown.bottle, id: \.slot) { piece in
                    if let ch = BreakableCountdown.character(in: clockText, slot: piece.slot) {
                        Text(String(ch)).font(font)
                            .rotationEffect(.radians(piece.angle))
                            .offset(x: piece.position.x, y: piece.position.y)
                    }
                }
            } else {
                Text(clockText)
                    .font(font)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: Int(remaining))
                    .scaleEffect(remaining <= 10 && remaining > 0 ? 1 + 0.06 * pulse : 1)
            }
        }
        .frame(width: ringSize, height: ringSize)
        .transformAnchorPreference(key: GlyphAnchorKey.self, value: .bounds) { $0["ring"] = $1 }
    }

    /// Feeds the meltdown where every breakable character is right now, then advances it a frame.
    private func tickMeltdown(anchors: [String: Anchor<CGRect>], geo: GeometryProxy, date: Date, headline: String) -> Bool {
        let heading = Array(headline), title = Array(meeting.title), clock = clockText
        var glyphs: [String: (CGRect, Character, GlyphStyle)] = [:]
        for (id, anchor) in anchors where id != "ring" {
            let parts = id.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[1]) else { continue }
            switch parts[0] {
            case "h" where n < heading.count: glyphs[id] = (geo[anchor], heading[n], .heading)
            case "t" where n < title.count: glyphs[id] = (geo[anchor], title[n], .title)
            case "d": if let ch = BreakableCountdown.character(in: clock, slot: n) { glyphs[id] = (geo[anchor], ch, .countdown) }
            default: break
            }
        }
        let ring = anchors["ring"].map { geo[$0] }
        let sound = state.prefs.alertSound
        meltdown.tick(date: date, secondsLate: -remaining, glyphs: glyphs,
                      ringCenter: ring.map { CGPoint(x: $0.midX, y: $0.midY) },
                      ringRadius: Double(ringSize) / 2 - 4, screen: geo.size) { piece in
            UIImpactFeedbackGenerator(style: piece == .letter ? .light : .rigid).impactOccurred()
            if sound { AudioServicesPlaySystemSound(piece == .letter ? 1104 : 1103) }
        }
        return true
    }
}

/// Keeps the pulse's phase continuous while its speed changes, so speeding up never makes the glow jump.
private final class PulseClock {
    private var phase = 0.0
    private var last: Date?

    func advance(to date: Date, period: Double) -> Double {
        if let last { phase += min(0.1, max(0, date.timeIntervalSince(last))) / max(period, 0.05) }
        last = date
        if phase > 10_000 { phase = phase.truncatingRemainder(dividingBy: 1) }
        return phase
    }
}
