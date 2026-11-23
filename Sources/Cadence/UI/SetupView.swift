import AppKit
import CadenceCore
import SwiftUI

/// First-launch setup, also reached from Settings → General → Run Setup Again: welcome, calendars,
/// alerts, startup and updates, done. Every choice is saved as it's made, so closing early keeps it;
/// nothing is reset when it runs again.
struct SetupView: View {
    enum Step: Int, CaseIterable { case welcome, calendars, alerts, startup, done }

    @Environment(AppState.self) private var state
    @State private var step: Step
    let finish: () -> Void

    init(step: Step = .welcome, finish: @escaping () -> Void) {
        _step = State(initialValue: step)
        self.finish = finish
    }

    static let width: CGFloat = 520
    static let height: CGFloat = 620

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep(next: { go(.calendars) })
                case .calendars: CalendarsStep()
                case .alerts: AlertsStep()
                case .startup: StartupStep()
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if step != .welcome { footer }
        }
        .frame(width: Self.width, height: Self.height)
        .background(.background)
    }

    private func go(_ next: Step) {
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if step != .done {
                    Button("Back") { go(Step(rawValue: step.rawValue - 1) ?? .welcome) }
                }
                StepDots(current: step)
                Spacer()
                switch step {
                case .calendars where state.calendars.isEmpty:
                    Button("Skip for Now") { go(.alerts) }.keyboardShortcut(.defaultAction)
                case .startup:
                    Button("Continue") {
                        // Choosing how to update is what marks setup as done.
                        if state.prefs.updateMode == nil { state.prefs.updateMode = .notify }
                        go(.done)
                    }
                    .keyboardShortcut(.defaultAction)
                case .done:
                    Button("Done", action: finish).keyboardShortcut(.defaultAction).controlSize(.large)
                default:
                    Button("Continue") { go(Step(rawValue: step.rawValue + 1) ?? .done) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Shared pieces

private struct StepDots: View {
    let current: SetupView.Step

    var body: some View {
        HStack(spacing: 5) {
            ForEach(SetupView.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == current ? AboutMascot.pink : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.leading, 6)
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(SetupView.Step.allCases.count)")
    }
}

private struct StepTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [AboutMascot.pink, AboutMascot.orange],
                                                startPoint: .leading, endPoint: .trailing))
            Text(detail)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A selectable card: an update mode or an alert preset.
struct OptionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background((selected ? AboutMascot.orange : Color.gray).gradient,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? AboutMascot.orange : .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AboutMascot.orange.opacity(0.12) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AboutMascot.orange.opacity(0.6) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One line in a list of sources or permissions: icon, title, status, and an action on the right.
private struct SetupRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = .secondary
    let title: String
    var status: String?
    var statusIsWarning = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium, design: .rounded))
                if let status {
                    Text(status)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(statusIsWarning ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// The sunburst and the calendar character from About, still and small, as a header.
struct MascotHeader: View {
    var mood: AboutMascot.Mood = .calm
    var height: CGFloat = 170

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height * 0.55)
                let t = timeline.date.timeIntervalSinceReferenceDate
                AboutMascot.drawSunburst(in: &ctx, size: size, center: center, time: t, mood: mood)
                AboutMascot.draw(in: &ctx, center: center, side: size.height * 0.72, time: t, mood: mood,
                                 pupils: [.zero, .zero], still: false)
            }
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Opens Settings on a tab, from a window that isn't part of a SwiftUI scene.
private struct OpenSettingsButton: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    let title: String
    let tab: SettingsTab

    var body: some View {
        Button(title) {
            state.settingsTab = tab
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}

// MARK: - 1 Welcome

private struct WelcomeStep: View {
    @Environment(AppState.self) private var state
    let next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MascotHeader(height: 210)
            VStack(alignment: .leading, spacing: 18) {
                StepTitle(title: "Welcome to Cadence",
                          detail: "Cadence watches your calendars and makes sure you're never late for a meeting. Setting up takes about a minute.")
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AboutMascot.orange)
                    Image(nsImage: MenuBarIcon.image(.calm))
                        .renderingMode(.template)
                        .foregroundStyle(.primary)
                    Text("Cadence lives in your menu bar, at the top of the screen (look for the arrow). Click its icon any time for today's meetings.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                if !MenuBarPointer.shared.iconVisible {
                    Label("Can't see the menu bar? A full-screen app may be hiding it. Move the pointer to the top of the screen and the arrow will show you the icon.",
                          systemImage: "cursorarrow.motionlines")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Coming from another Mac? Import settings…") {
                        SettingsTransfer.chooseAndImport(state)
                        // Accounts aren't in a settings file, so carry on to connecting calendars.
                        if state.prefs.setupDone { next() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12, design: .rounded))
                    Spacer()
                    Button("Get Started", action: next)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
            .padding(22)
        }
        .onAppear { MenuBarPointer.shared.show() }
        .onDisappear { MenuBarPointer.shared.hide() }
    }
}

// MARK: - 2 Calendars

private struct CalendarsStep: View {
    @Environment(AppState.self) private var state
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        // Provider status isn't observable itself; every provider change triggers a refresh.
        let _ = state.lastRefresh
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Connect your calendars",
                      detail: "Cadence reads your meetings to warn you before they start. It never changes them without asking.")
            VStack(spacing: 6) {
                macCalendarRow
                googleRow
                microsoftRow
                SetupRow(symbol: "link", title: "Calendar link (ICS)",
                         status: feedStatus) {
                    OpenSettingsButton(title: "Add…", tab: .accounts)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if !state.calendars.isEmpty { calendarPicker }
        }
        .padding(22)
    }

    // macOS Calendar: the system prompt only appears on Allow Access, after the line above has said why.
    @ViewBuilder private var macCalendarRow: some View {
        let mine = state.calendars.filter { ![.google, .microsoft, .ics].contains($0.kind) }
        switch state.access {
        case .granted:
            SetupRow(symbol: "calendar", tint: .red, title: "Mac Calendar",
                     status: "\(count(mine.count, "calendar")) · iCloud, Google, Exchange and more from Internet Accounts") {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .denied:
            SetupRow(symbol: "calendar", tint: .red, title: "Mac Calendar",
                     status: "Access is off. Turn on Cadence under Privacy & Security → Calendars.", statusIsWarning: true) {
                Button("Open System Settings", action: state.openPrivacySettings)
            }
        default:
            SetupRow(symbol: "calendar", tint: .red, title: "Mac Calendar",
                     status: "Every account in System Settings → Internet Accounts") {
                Button("Allow Access") { Task { await state.requestAccess() } }
            }
        }
    }

    @ViewBuilder private var googleRow: some View {
        let auth = state.googleAuth
        let n = state.calendars.filter { $0.kind == .google }.count
        SetupRow(symbol: "g.circle.fill", tint: .blue, title: "Google Calendar",
                 status: auth.accounts.isEmpty ? "Direct sign-in: event colours, RSVPs and running-late emails"
                     : "\(auth.accounts.map(\.label).joined(separator: ", ")) · \(count(n, "calendar"))") {
            if auth.hasBundledClient {
                Button(busy == "google" ? "Waiting for browser…" : (auth.accounts.isEmpty ? "Connect" : "Add Another")) {
                    signIn("google") { try await state.googleSignIn() }
                }
                .disabled(busy != nil)
            } else {
                OpenSettingsButton(title: "Set Up…", tab: .accounts)
            }
        }
    }

    @ViewBuilder private var microsoftRow: some View {
        let auth = state.microsoftAuth
        let n = state.calendars.filter { $0.kind == .microsoft }.count
        SetupRow(symbol: "m.square.fill", tint: .cyan, title: "Microsoft 365 / Outlook",
                 status: auth.accounts.isEmpty ? "Direct sign-in: Teams links, RSVPs and replies"
                     : "\(auth.accounts.map(\.label).joined(separator: ", ")) · \(count(n, "calendar"))") {
            if auth.hasBundledClient {
                Button(busy == "microsoft" ? "Waiting for browser…" : (auth.accounts.isEmpty ? "Connect" : "Add Another")) {
                    signIn("microsoft") { try await state.microsoftSignIn() }
                }
                .disabled(busy != nil)
            } else {
                OpenSettingsButton(title: "Set Up…", tab: .accounts)
            }
        }
    }

    private var feedStatus: String {
        let feeds = state.prefs.icsFeeds
        return feeds.isEmpty ? "A subscribed link from any calendar app" : feeds.map(\.name).joined(separator: ", ")
    }

    private var calendarPicker: some View {
        let grouped = Dictionary(grouping: state.calendars, by: \.sourceTitle).sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Watch these calendars")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(count(state.todayMeetings.filter { !$0.isAllDay }.count, "meeting")) today")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(grouped, id: \.key) { source, calendars in
                        Text(source.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        ForEach(calendars) { cal in
                            Toggle(isOn: Binding(get: { state.isCalendarEnabled(cal.id) },
                                                 set: { state.setCalendar(cal.id, enabled: $0) })) {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(cal.color)).frame(width: 9, height: 9)
                                    Text(cal.title).font(.system(size: 12, design: .rounded))
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            Text("Turn off holidays, birthdays and anything you don't want alerts for. More options in Settings → Calendars.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private func signIn(_ which: String, _ action: @escaping () async throws -> Void) {
        busy = which
        error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }
}

private func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

// MARK: - 3 Alerts

private struct AlertsStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "How loud should Cadence be?",
                      detail: "Pick a starting point. You can fine-tune every alert in Settings → Alerts.")
            VStack(spacing: 8) {
                ForEach(AlertPreset.allCases) { preset in
                    OptionCard(symbol: preset.symbol, title: preset.label, detail: preset.detail,
                               selected: state.alertPreset == preset) { state.alertPreset = preset }
                }
                if state.alertPreset == nil {
                    Text("Your alerts are tuned by hand in Settings. Pick one above only to replace them.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button {
                    state.previewSetupAlert(state.alertPreset ?? .normal)
                } label: {
                    Label("Show Me an Alert", systemImage: "play.fill")
                }
                Text((state.alertPreset ?? .normal).takesOverScreen
                     ? "This fills your screen for a moment. Esc closes it."
                     : "A sample notification about a made-up meeting.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            notificationsRow
        }
        .padding(22)
        .task { await state.refreshNotificationStatus() }
    }

    @ViewBuilder private var notificationsRow: some View {
        switch state.notificationsAllowed {
        case true?:
            SetupRow(symbol: "bell.badge", tint: AboutMascot.orange, title: "Notifications",
                     status: "Allowed: heads-ups, invites and the morning summary can reach you") {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case false?:
            SetupRow(symbol: "bell.slash", tint: .orange, title: "Notifications are off",
                     status: "Heads-ups and invites can't reach you. Turn on Cadence in System Settings → Notifications.",
                     statusIsWarning: true) {
                Button("Open System Settings", action: state.openNotificationSettings)
            }
        case nil:
            SetupRow(symbol: "bell.badge", tint: AboutMascot.orange, title: "Notifications",
                     status: "For heads-ups, new invites and the morning summary. macOS asks once.") {
                Button("Allow Notifications") { Task { await state.requestNotifications() } }
            }
        }
    }
}

// MARK: - 4 Startup and updates

private struct StartupStep: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var mode: UpdateMode = .notify

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Stay running",
                      detail: "Two quick choices so Cadence is there when a meeting comes round.")
            SetupRow(symbol: "power", tint: .green, title: "Open Cadence when I log in",
                     status: loginError ?? "Otherwise you'll need to open it again after a restart",
                     statusIsWarning: loginError != nil) {
                if loginError != nil {
                    Button("Open Login Items", action: LoginItem.openSettings)
                } else {
                    Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                }
            }
            Text("How should Cadence stay up to date?")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.top, 4)
            VStack(spacing: 8) {
                ForEach([UpdateMode.notify, .automatic, .off]) { option in
                    OptionCard(symbol: option.symbol, title: option.label + (option == .notify ? " (recommended)" : ""),
                               detail: option.detail, selected: mode == option) {
                        mode = option
                        state.prefs.updateMode = option
                    }
                }
            }
        }
        .padding(22)
        .onAppear { mode = state.prefs.updateMode ?? .notify }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = LoginItem.set(on)
        if loginError != nil { launchAtLogin = LoginItem.isEnabled }
    }
}

// MARK: - 5 Done

private struct DoneStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            MascotHeader(height: 130)
            VStack(alignment: .leading, spacing: 14) {
                StepTitle(title: "You're all set",
                          detail: "Cadence is watching your calendars from the menu bar.")
                nextMeeting
                VStack(alignment: .leading, spacing: 6) {
                    Text("When you're ready")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    extra("globe", "Open meeting links in the right browser profile", .browser)
                    extra("paperplane", "Send running-late messages in one click", .messages)
                    extra("briefcase", "Set your working hours and breaks", .work)
                    extra("music.note", "Fade out music when a meeting starts", .alerts)
                    extra("sparkles", "Let an AI assistant see your calendar", .assistants)
                }
                if !state.setupTasks.isEmpty {
                    Text("Skipped steps wait in the menu as a checklist until they're done.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder private var nextMeeting: some View {
        if let next = state.next {
            SetupRow(symbol: "clock.fill", tint: next.tint, title: "Next: \(next.title)",
                     status: "\(relative(next.start))\(alertLine(next).map { " · \($0)" } ?? "")") {
                EmptyView()
            }
        } else {
            SetupRow(symbol: "sun.max.fill", tint: .yellow, title: "Nothing coming up yet",
                     status: state.calendars.isEmpty ? "Connect a calendar any time from the menu."
                                                     : "Cadence will speak up before your next meeting.") {
                EmptyView()
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        return f.localizedString(for: date, relativeTo: state.now)
    }

    /// When the first alert for `m` will fire, with the settings chosen a step ago.
    private func alertLine(_ m: Meeting) -> String? {
        let prefs = state.prefs
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        if prefs.headsUpEnabled { return "Notification at \(time(m.start.addingTimeInterval(-Double(prefs.headsUpMinutes) * 60)))" }
        if prefs.takeoverEnabled { return "Full-screen alert at \(time(m.start.addingTimeInterval(-prefs.takeoverLeadSeconds)))" }
        return nil
    }

    private func extra(_ symbol: String, _ title: String, _ tab: SettingsTab) -> some View {
        ExtraRow(symbol: symbol, title: title, tab: tab)
    }
}

private struct ExtraRow: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    let symbol: String
    let title: String
    let tab: SettingsTab

    var body: some View {
        Button {
            state.settingsTab = tab
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, design: .rounded))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
