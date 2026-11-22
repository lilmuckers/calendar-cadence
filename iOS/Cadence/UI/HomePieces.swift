import CadenceCore
import SwiftUI
import TipKit

/// Desk mode on the home screen: a small desk display showing what the real one would (the next
/// meeting counting down, or all clear), so it reads as the main feature rather than a setting.
struct DeskTile: View {
    @Environment(PhoneState.self) private var state
    var open: () -> Void

    var body: some View {
        let focus = state.focus
        let tint = focus?.meeting.tint ?? Color(SampleCalendar.info.color)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(kicker(focus))
                        .font(.system(size: 11, weight: .heavy)).kerning(1.4)
                        .foregroundStyle(focus == nil ? .white.opacity(0.6) : tint)
                    Spacer()
                    Label("Desk Mode", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                if let focus {
                    Text(CountdownFormatter.clock(focus.target.timeIntervalSince(state.now)))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.default, value: Int(focus.target.timeIntervalSince(state.now)))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(focus.meeting.title).font(.headline).lineLimit(1)
                } else {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("All clear").font(.system(size: 32, weight: .bold, design: .rounded))
                            Text("No more meetings today.").font(.subheadline).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        GooglyTeaBreak(height: 44).foregroundStyle(.white).opacity(0.85)
                    }
                }
                Text(state.prefs.deskWhenCharging ? "Turns on by itself while charging. Tap to open now."
                     : "Tap to keep the countdown on screen.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 2)
            }
            .padding(16)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black)
                    .overlay(
                        RadialGradient(colors: [tint.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .accessibilityHint("Opens desk mode")
    }

    private func kicker(_ focus: PanelFocus?) -> String {
        guard let focus else { return "TODAY" }
        if focus.live { return "ENDS IN" }
        return Calendar.current.isDate(focus.meeting.start, inSameDayAs: state.now) ? "UP NEXT" : "TOMORROW"
    }
}

/// The home screen before anything's connected: what it'll look like, and the ways to get started.
struct EmptyHome: View {
    @Environment(PhoneState.self) private var state
    @Binding var showSettings: Bool
    @Binding var showPairing: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                DeskPreviewCard()
                    .frame(maxWidth: 420)
                    .padding(.top, 8)
                VStack(spacing: 6) {
                    Text("Connect a calendar to start")
                        .font(.title3.weight(.bold))
                    Text("Cadence counts down to your next meeting and alerts you just before it starts.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 10) {
                    Button { showSettings = true } label: {
                        Label("Connect a Calendar", systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { showPairing = true } label: {
                        Label("Pair with Cadence on Your Mac", systemImage: "laptopcomputer.and.iphone")
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    Button("Try with Sample Meetings") {
                        withAnimation(Theme.spring) { state.setSample(true) }
                    }
                    .font(.callout.weight(.medium))
                    .padding(.top, 4)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// One-off hints, each shown once: desk mode once there are meetings, then pull to refresh.
enum CadenceTips {
    static let desk = DeskTip()
    static let refresh = RefreshTip()

    @MainActor static var hasMeetings: Bool {
        get { DeskTip.hasMeetings }
        set { DeskTip.hasMeetings = newValue }
    }

    @MainActor static var deskTipDone: Bool {
        get { RefreshTip.deskTipDone }
        set { RefreshTip.deskTipDone = newValue }
    }

    struct DeskTip: Tip {
        @Parameter static var hasMeetings: Bool = false

        var title: Text { Text("Put it on a charger") }
        var message: Text? { Text("On a MagSafe stand or any charger, Cadence turns into a desk display by itself.") }
        var image: Image? { Image(systemName: "bolt.fill") }
        var rules: [Rule] { [#Rule(Self.$hasMeetings) { $0 }] }
    }

    struct RefreshTip: Tip {
        @Parameter static var deskTipDone: Bool = false

        var title: Text { Text("Pull down to refresh") }
        var message: Text? { Text("Fetches your calendars straight away instead of waiting for the next check.") }
        var image: Image? { Image(systemName: "arrow.down") }
        var rules: [Rule] { [#Rule(Self.$deskTipDone) { $0 }] }
    }
}
