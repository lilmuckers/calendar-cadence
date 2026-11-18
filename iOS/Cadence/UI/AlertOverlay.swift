import CadenceCore
import SwiftUI

/// The phone's full-screen "starting now" alert, the twin of the Mac's takeover.
struct AlertOverlay: View {
    @Environment(PhoneState.self) private var state
    let meeting: Meeting
    @State private var pulse = false

    var body: some View {
        let remaining = meeting.start.timeIntervalSince(state.now)
        ZStack {
            LinearGradient(colors: [meeting.tint, meeting.tint.opacity(0.55), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Text(remaining > 0 ? "STARTING IN" : "STARTED")
                    .font(.headline.weight(.heavy)).kerning(2).opacity(0.8)
                Text(remaining > 0 ? CountdownFormatter.clock(remaining) : CountdownFormatter.short(-remaining) + " ago")
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .scaleEffect(pulse && remaining <= 10 && remaining > 0 ? 1.06 : 1)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: pulse)
                Text(meeting.title)
                    .font(.system(size: 34, weight: .bold)).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.6)
                Text("\(Theme.range(meeting)) · \(Theme.detail(meeting))")
                    .font(.title3).opacity(0.8).multilineTextAlignment(.center)
                Spacer()
                if meeting.joinLink != nil {
                    JoinButton(meeting: meeting, scale: 1.2)
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
        }
        .onAppear { pulse = true }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}
