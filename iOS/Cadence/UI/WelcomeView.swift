import CadenceCore
import SwiftUI

/// First launch: three pages in the desk display's look. What Cadence does (with a live countdown),
/// where meetings come from (or sample meetings), then alerts and desk mode, which is where
/// notifications are asked for. Skippable from any page; never shown again once finished.
struct WelcomeView: View {
    @Environment(PhoneState.self) private var state
    @State private var page = WelcomeView.firstPage

    /// `-previewWelcome 2`: open on that page, for checking the layout.
    private static var firstPage: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-previewWelcome"), args.indices.contains(i + 1), let p = Int(args[i + 1]) { return p }
        #endif
        return 0
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            background
            TabView(selection: $page) {
                HeroPage { go(1) }.tag(0)
                SourcesPage { go(2) }.tag(1)
                AlertsPage { finish() }.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            if page < 2 {
                Button("Skip") { finish() }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 20).padding(.top, 8)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        let tint: Color = switch page {
        case 0: SampleCalendar.info.color.swiftUI
        case 1: AboutMascot.pink
        default: AboutMascot.orange
        }
        return ZStack {
            Color.black
            RadialGradient(colors: [tint.opacity(0.4), .clear], center: .topLeading, startRadius: 0, endRadius: 650)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: page)
    }

    private func go(_ p: Int) { withAnimation(Theme.spring) { page = p } }

    private func finish() { state.prefs.welcomeSeen = true }
}

private extension RGBAColor {
    var swiftUI: Color { Color(self) }
}

// MARK: - Pages

/// A big live countdown and what Cadence is for.
private struct HeroPage: View {
    var next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            DeskPreviewCard()
                .padding(.horizontal, 28)
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                Text("Your next meeting,\nalways in view")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Cadence counts down to every meeting, puts Join one tap away, and turns your iPhone into a desk display while it charges.")
                    .font(.body).foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 24)
            WelcomeButton("Get Started", action: next)
                .padding(.horizontal, 28).padding(.bottom, 56)
        }
    }
}

/// Where meetings come from: each option ticks itself off once it's connected.
private struct SourcesPage: View {
    @Environment(PhoneState.self) private var state
    var next: () -> Void
    @State private var showPairing = false
    @State private var showFeeds = false
    @State private var authError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Where are your meetings?")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .padding(.top, 52)
                    Text("Connect as many as you like. Cadence merges them and removes duplicates.")
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.bottom, 6)

                    SourceRow(title: "Cadence on your Mac", detail: macDetail, symbol: "laptopcomputer.and.iphone",
                              done: !state.link.links.isEmpty) { showPairing = true }
                    SourceRow(title: "iPhone Calendar", detail: "iCloud, Exchange and other accounts in Settings",
                              symbol: "calendar", done: state.calendarAccess) {
                        if state.calendarAccessDenied {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } else {
                            Task { await state.requestCalendarAccess() }
                        }
                    }
                    if state.googleAuth.credentials != nil || !state.googleAuth.accounts.isEmpty {
                        accountButton(.google, accounts: state.googleAuth.accounts.map(\.label)) {
                            try await state.googleSignIn()
                        }
                    }
                    if state.microsoftAuth.clientID != nil || !state.microsoftAuth.accounts.isEmpty {
                        accountButton(.microsoft, accounts: state.microsoftAuth.accounts.map(\.label)) {
                            try await state.microsoftSignIn()
                        }
                    }
                    SourceRow(title: "Calendar link", detail: "Any webcal:// or ICS address", symbol: "link",
                              done: !state.prefs.icsFeeds.isEmpty) { showFeeds = true }

                    HStack {
                        VStack { Divider().overlay(.white.opacity(0.2)) }
                        Text("or").font(.caption).foregroundStyle(.white.opacity(0.5))
                        VStack { Divider().overlay(.white.opacity(0.2)) }
                    }
                    .padding(.vertical, 4)
                    SourceRow(title: "Try with sample meetings", detail: "A made-up day, to see how it works. Remove it any time.",
                              symbol: "sparkles", done: state.usingSample) {
                        state.setSample(!state.usingSample)
                    }
                }
                .padding(.horizontal, 24)
                .animation(Theme.spring, value: state.hasRealSource)
                .animation(Theme.spring, value: state.usingSample)
            }
            .scrollIndicators(.hidden)
            WelcomeButton(state.hasRealSource || state.usingSample ? "Continue" : "Set Up Later", action: next)
                .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 56)
        }
        .sheet(isPresented: $showPairing) { PairingScreen() }
        .sheet(isPresented: $showFeeds) {
            NavigationStack {
                CalendarsScreen()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFeeds = false } } }
            }
            .preferredColorScheme(nil)
        }
        .alert("Sign-in failed", isPresented: Binding(get: { authError != nil }, set: { if !$0 { authError = nil } })) {
            Button("OK") {}
        } message: { Text(authError ?? "") }
    }

    private var macDetail: String {
        let names = state.link.links.map(\.mac.displayName)
        return names.isEmpty ? "Scan the pairing code from Cadence's settings on the Mac" : names.formatted(.list(type: .and))
    }

    /// The provider's own branded button, with a tick and the accounts underneath once signed in.
    private func accountButton(_ provider: ProviderSignInButton.Provider, accounts: [String],
                               signIn: @escaping () async throws -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProviderSignInButton(provider: provider) {
                Task { do { try await signIn() } catch { authError = error.localizedDescription } }
            }
            .environment(\.colorScheme, .dark)
            ForEach(accounts, id: \.self) { label in
                Label(label, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }
}

/// Alerts and desk mode; the one place the notification prompt comes from on first launch.
private struct AlertsPage: View {
    @Environment(PhoneState.self) private var state
    var done: () -> Void
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Never miss the start")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .padding(.top, 52).padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 22) {
                feature("rectangle.inset.filled", tint: AboutMascot.pink, title: "A full-screen alert",
                        detail: "Just before each meeting, with Join right there.")
                feature("bell.badge.fill", tint: AboutMascot.orange, title: "Notifications",
                        detail: "Heads-ups and alerts while Cadence isn't open.")
                feature("iphone.gen3.radiowaves.left.and.right", tint: .indigo, title: "Desk mode",
                        detail: "Put your iPhone on a charger or MagSafe stand and it becomes a desk display.")
                feature("lock.iphone", tint: .blue, title: "Lock Screen and Dynamic Island",
                        detail: "A Live Activity counts down to the next meeting.")
            }
            Spacer(minLength: 24)
            WelcomeButton(asking ? "…" : "Turn On Notifications") {
                asking = true
                Task {
                    await state.askForNotifications()
                    done()
                }
            }
            .disabled(asking)
            Button("Not Now", action: done)
                .font(.body.weight(.medium)).foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity).padding(.top, 14).padding(.bottom, 44)
        }
        .padding(.horizontal, 28)
    }

    private func feature(_ symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2).foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}

// MARK: - Pieces

/// One way to bring meetings in, ticked once it's connected.
private struct SourceRow: View {
    let title: String
    let detail: String
    let symbol: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: done ? "checkmark.circle.fill" : "chevron.right")
                    .font(done ? .title3 : .footnote.weight(.semibold))
                    .foregroundStyle(done ? .green : .white.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(.white.opacity(done ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: done) { old, new in !old && new }
    }
}

/// The big white button along the bottom of each page.
private struct WelcomeButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A small desk display with a made-up meeting counting down on a loop, for the welcome and the
/// empty home screen: what Cadence will look like once there are meetings.
struct DeskPreviewCard: View {
    /// When the loop started; the countdown runs from 4:59 down to 0:00 and starts again.
    @State private var anchor = Date()
    private let loop: TimeInterval = 5 * 60

    var body: some View {
        let tint = Color(SampleCalendar.info.color)
        TimelineView(.periodic(from: anchor, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(anchor).truncatingRemainder(dividingBy: loop)
            let remaining = loop - 1 - elapsed
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("UP NEXT")
                        .font(.system(size: 12, weight: .heavy)).kerning(1.5)
                        .foregroundStyle(tint)
                    Spacer()
                    GooglyIcon(mood: remaining < 60 ? .panicking : remaining < 180 ? .nervous : .calm, height: 18)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(CountdownFormatter.clock(remaining))
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: Int(remaining))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("Design review")
                    .font(.system(size: 22, weight: .bold))
                Label("Jitsi · 4 people", systemImage: "video.fill")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.65))
                Text("Join")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(tint, in: Capsule())
                    .padding(.top, 6)
            }
        }
        .padding(20)
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RadialGradient(colors: [tint.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: Design review, up next, with a countdown and a Join button")
    }
}
