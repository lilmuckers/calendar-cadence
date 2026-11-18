import CadenceCore
import SwiftUI
import UIKit

/// The phone's full-screen "starting now" alert, the twin of the Mac's takeover. Once the meeting has
/// started it escalates the same way (`TakeoverUrgency`): the glow speeds up and widens, the colour
/// turns red, the edges flash and, near full panic, the content shakes.
struct AlertOverlay: View {
    @Environment(PhoneState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let meeting: Meeting
    @State private var clock = PulseClock()

    private var remaining: TimeInterval { meeting.start.timeIntervalSince(state.now) }
    private var urgency: TakeoverUrgency { TakeoverUrgency(secondsLate: -remaining) }
    private var headline: String { TakeoverUrgency.headline(remaining: remaining) }

    var body: some View {
        TimelineView(.animation) { context in
            let u = urgency
            let phase = clock.advance(to: context.date, period: reduceMotion ? 2 : u.period)
            let pulse = (1 - cos(phase * 2 * .pi)) / 2
            content(urgency: u, phase: phase, pulse: reduceMotion ? 0.5 : pulse)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        // Each step up in the headline ("YOU'RE LATE" …) taps the wrist, so to speak.
        .onChange(of: headline) { _, _ in
            if remaining < 0 { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
    }

    @ViewBuilder private func content(urgency u: TakeoverUrgency, phase: Double, pulse: Double) -> some View {
        let mood = Color(u.color(from: meeting.displayColor))
        let shake = reduceMotion ? 0 : u.shake
        ZStack {
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

            VStack(spacing: 18) {
                Spacer()
                Text(headline)
                    .font(.system(size: 17 + 5 * u.level, weight: .heavy)).kerning(2)
                    .multilineTextAlignment(.center)
                    .opacity(u.level > 0 ? 1 : 0.8)
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: headline)
                Text(remaining > 0 ? CountdownFormatter.clock(remaining) : "-" + CountdownFormatter.clock(-remaining))
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .scaleEffect(remaining <= 10 && remaining > 0 ? 1 + 0.06 * pulse : 1)
                Text(meeting.title)
                    .font(.system(size: 34, weight: .bold)).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.6)
                Text("\(Theme.range(meeting)) · \(Theme.detail(meeting))")
                    .font(.title3).opacity(0.8).multilineTextAlignment(.center)
                Spacer()
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
        .ignoresSafeArea()
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
