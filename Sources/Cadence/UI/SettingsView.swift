import CadenceCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            CalendarsTab().tabItem { Label("Calendars", systemImage: "calendar") }
            FiltersTab().tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
            AlertsTab().tabItem { Label("Alerts", systemImage: "bell.badge") }
            WorkTab().tabItem { Label("Work", systemImage: "briefcase") }
            PhoneTab().tabItem { Label("iPhone", systemImage: "iphone") }
            MessagesTab().tabItem { Label("Messages", systemImage: "paperplane") }
            BrowserTab().tabItem { Label("Browser", systemImage: "globe") }
            AssistantsTab().tabItem { Label("Assistants", systemImage: "sparkles") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 580, height: 520)
    }
}

private struct WorkTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            WorkScheduleEditor(schedule: $state.prefs.workSchedule,
                               defencesFooter: "Nudges and break questions also go to your paired iPhone. A meeting over a break asks like a double-booking: keep the break (the meeting won't alert) or give it up for the day.")
        }
        .formStyle(.grouped)
    }
}

private struct CalendarsTab: View {
    @Environment(AppState.self) private var state

    private var grouped: [(String, [CalendarInfo])] {
        Dictionary(grouping: state.calendars, by: \.sourceTitle)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        Form {
            if state.access != .granted {
                Section {
                    Text("Cadence needs calendar access to read your events.")
                    Button("Open Privacy Settings", action: state.openPrivacySettings)
                }
            }
            Section {
                Text("Switch individual calendars on or off. The bell makes a calendar agenda only: its events still show, but never alert, remind, clash or count as your current or next meeting. Add sources in the Accounts tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(isOn: Binding(get: { state.prefs.useEventColors }, set: { state.prefs.useEventColors = $0 })) {
                    Text("Use event colours")
                    Text("Events coloured individually in Google Calendar (or with a colour in an ICS feed) use that colour instead of their calendar's. Google event colours need the direct Google sign-in; macOS Calendar doesn't pass them on.")
                }
                Toggle(isOn: Binding(get: { state.prefs.namedColorsOnly }, set: { state.prefs.namedColorsOnly = $0 })) {
                    Text("Only offer named colours")
                    Text("When picking a colour for a Google event, show just the colours you've named in Google Calendar, hiding the stock and unnamed custom ones. Calendars with no named colours still show them all.")
                }
            }
            ForEach(grouped, id: \.0) { source, calendars in
                Section {
                    if state.browsers.supportsProfiles {
                        accountProfileRow(source)
                    }
                    ForEach(calendars) { cal in
                        Toggle(isOn: Binding(get: { state.isCalendarEnabled(cal.id) },
                                             set: { state.setCalendar(cal.id, enabled: $0) })) {
                            HStack(spacing: 8) {
                                Circle().fill(Color(cal.color)).frame(width: 10, height: 10)
                                Text(cal.title)
                                Spacer()
                                let asks = state.prefs.colorPromptCalendarIDs.contains(cal.id)
                                Button {
                                    if asks { state.prefs.colorPromptCalendarIDs.remove(cal.id) } else { state.prefs.colorPromptCalendarIDs.insert(cal.id) }
                                } label: {
                                    Image(systemName: asks ? "paintpalette.fill" : "paintpalette")
                                        .foregroundStyle(asks ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(asks ? "Invites on this calendar ask for a colour" : "Ask for a colour when reviewing invites on this calendar")
                                let quiet = state.isCalendarAgendaOnly(cal.id)
                                Button {
                                    state.setCalendar(cal.id, agendaOnly: !quiet)
                                } label: {
                                    Image(systemName: quiet ? "bell.slash.fill" : "bell")
                                        .foregroundStyle(quiet ? Color.orange : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(quiet ? "Agenda only: shown in the agenda, but no alerts, reminders, clashes or assistant events. Click to turn alerts back on."
                                            : "Make agenda only: keep it in the agenda, but leave it out of alerts, reminders, clashes and automations")
                                if state.browsers.supportsProfiles {
                                    calendarProfileMenu(cal.id)
                                }
                            }
                        }
                    }
                } header: {
                    Text(source)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.browsers.refresh() }
    }

    /// A small globe menu per calendar: filled and tinted when the calendar has its own profile.
    @ViewBuilder private func calendarProfileMenu(_ id: String) -> some View {
        let store = state.browsers
        let current = state.prefs.profileRules.calendars[id]
        let profile = store.profile(id: current)
        Menu {
            Button {
                state.prefs.profileRules.calendars[id] = nil
            } label: {
                if current == nil { Label("Same as Account", systemImage: "checkmark") } else { Text("Same as Account") }
            }
            Divider()
            ForEach(store.profiles) { p in
                Button {
                    state.prefs.profileRules.calendars[id] = p.id
                } label: {
                    if current == p.id { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                }
            }
        } label: {
            Image(systemName: current == nil ? "globe" : "globe.badge.chevron.backward")
                .foregroundStyle(current == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(profile.map { "Meeting links open in \($0.title)" } ?? "Meeting links use the account's browser profile")
    }

    @ViewBuilder private func accountProfileRow(_ source: String) -> some View {
        let current = state.prefs.profileRules.accounts[source]
        let suggestion = current == nil ? ProfileResolver.suggest(accountTitle: source, profiles: state.browsers.profiles) : nil
        LabeledContent {
            HStack(spacing: 8) {
                if let suggestion {
                    Button("Use \(suggestion.title)") { state.prefs.profileRules.accounts[source] = suggestion.id }
                        .help("This \(state.browsers.defaultBrowserName) profile is signed in as the same account")
                }
                Picker("", selection: Binding(get: { state.prefs.profileRules.accounts[source] },
                                              set: { state.prefs.profileRules.accounts[source] = $0 })) {
                    ProfilePickerOptions(store: state.browsers, noneLabel: "Default", current: current)
                }
                .labelsHidden()
                .fixedSize()
            }
        } label: {
            Label("Open meeting links in", systemImage: "globe")
        }
    }
}

private struct FiltersTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Hide") {
                Toggle("All-day events", isOn: $state.prefs.filters.hideAllDay)
                Toggle("Declined invitations", isOn: $state.prefs.filters.hideDeclined)
                Toggle("Tentative / maybe", isOn: $state.prefs.filters.hideTentative)
                Toggle("Events marked as free", isOn: $state.prefs.filters.hideFree)
                Toggle("Events without a meeting link", isOn: $state.prefs.filters.onlyWithJoinLink)
                Stepper(value: $state.prefs.filters.minimumDurationMinutes, in: 0...240, step: 5) {
                    Text(state.prefs.filters.minimumDurationMinutes == 0
                         ? "Any duration"
                         : "Shorter than \(state.prefs.filters.minimumDurationMinutes) min")
                }
            }
            Section {
                KeywordField(title: "Hide titles containing", placeholder: "lunch, focus, OOO", words: $state.prefs.filters.excludeKeywords)
                KeywordField(title: "Only titles containing", placeholder: "Leave empty to show all", words: $state.prefs.filters.includeKeywords)
            } header: {
                Text("Keywords")
            } footer: {
                Text("Comma-separated, case-insensitive.").foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Showing today", value: "\(state.todayMeetings.count) of \(todayTotal) events")
            }
        }
        .formStyle(.grouped)
    }

    private var todayTotal: Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: state.now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return state.allMeetings.filter { $0.end > start && $0.start < end }.count
    }
}

private struct KeywordField: View {
    let title: String
    let placeholder: String
    @Binding var words: [String]
    @State private var text = ""

    var body: some View {
        TextField(title, text: $text, prompt: Text(placeholder))
            .onAppear { text = words.joined(separator: ", ") }
            .onSubmit(commit)
            .onChange(of: text) { commit() }
    }

    private func commit() {
        words = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private struct AlertsTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Full-screen alert") {
                Toggle("Take over the screen before meetings", isOn: $state.prefs.takeoverEnabled)
                Picker("Show", selection: $state.prefs.takeoverLeadSeconds) {
                    Text("10 seconds before").tag(10.0)
                    Text("30 seconds before").tag(30.0)
                    Text("1 minute before").tag(60.0)
                    Text("2 minutes before").tag(120.0)
                    Text("5 minutes before").tag(300.0)
                }
                .disabled(!state.prefs.takeoverEnabled)
                Toggle("Cover all displays", isOn: $state.prefs.takeoverAllScreens)
                Toggle("Only for meetings with a join link", isOn: $state.prefs.takeoverOnlyWithLink)
                Toggle("Play sound", isOn: $state.prefs.takeoverSound)
                Picker(selection: $state.prefs.takeoverAutoDismissMinutes) {
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("Never — stay until I act").tag(0)
                } label: {
                    Text("If ignored, close after the start by")
                    Text("It gets redder and more frantic for the first 3 minutes you're late.")
                }
                .disabled(!state.prefs.takeoverEnabled)
            }
            Section {
                Toggle("Fade out music for meetings", isOn: $state.prefs.fadeMediaForAlerts)
                Toggle("Say which meeting it is", isOn: $state.prefs.announceAlerts)
                    .disabled(!state.prefs.fadeMediaForAlerts)
                Toggle("Share music with your iPhone", isOn: $state.prefs.shareMediaWithPhone)
                Button("Test") { state.onTestMediaFade?() }
            } header: { Text("Music") } footer: {
                Text("Works with Music and Spotify (macOS asks once to let Cadence control them). The voice is your Spoken Content system voice. Sharing shows this Mac's music on the iPhone's desk display with play, pause and skip.")
            }
            MediaRemoteSection()
            Section {
                Picker("While presenting or sharing", selection: $state.prefs.whilePresenting) {
                    ForEach(BusyAlertStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("While on a call", selection: $state.prefs.whileOnCall) {
                    ForEach(BusyAlertStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledContent("Right now") {
                    Text(status).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("When you're busy")
            } footer: {
                Text("Presenting means a Keynote/PowerPoint slideshow, or the border Zoom and Teams draw around a shared screen. Displays being presented are never covered. On a call means an app is using the microphone.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Heads-up notification", isOn: $state.prefs.headsUpEnabled)
                Stepper(value: $state.prefs.headsUpMinutes, in: 1...60) {
                    Text("\(state.prefs.headsUpMinutes) min before")
                }
                .disabled(!state.prefs.headsUpEnabled)
                Toggle("\"Leave now\" for in-person meetings", isOn: $state.prefs.leaveEnabled)
                OffsetsField(offsets: $state.prefs.leaveOffsets)
                    .disabled(!state.prefs.leaveEnabled)
                Toggle("Ask which meeting to alert for when two clash", isOn: $state.prefs.clashPromptEnabled)
                LabeledContent("Clash choices") {
                    HStack {
                        Text(state.clashChoices.isEmpty ? "None — right-click a clashing event to choose" : "\(state.clashChoices.count) saved")
                            .foregroundStyle(.secondary)
                        if !state.clashChoices.isEmpty {
                            Button("Reset") { state.resetClashChoices() }
                                .help("Alert for every clashing meeting and ask again")
                        }
                    }
                }
                Toggle(isOn: $state.prefs.wrapUpEnabled) {
                    Text("Wrap-up nudge before meetings end")
                    Text("Names the next meeting when one starts straight after. For online meetings, only while your mic is still in use.")
                }
                Stepper(value: $state.prefs.wrapUpMinutes, in: 1...30) {
                    Text("\(state.prefs.wrapUpMinutes) min before the end")
                }
                .disabled(!state.prefs.wrapUpEnabled)
                Toggle("Only when another meeting follows", isOn: $state.prefs.wrapUpOnlyBackToBack)
                    .disabled(!state.prefs.wrapUpEnabled)
                Toggle("Morning summary", isOn: $state.prefs.summaryEnabled)
                DatePicker("Send at", selection: summaryTime, displayedComponents: .hourAndMinute)
                    .disabled(!state.prefs.summaryEnabled)
            } header: {
                Text("Reminders")
            } footer: {
                Text("Leave reminders use live travel time (Settings → General → Travel time by) and re-check traffic every 15 minutes. Offsets are minutes before you need to leave; 0 means \"time to leave\".")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Look for invites", selection: $state.prefs.inviteHorizon) {
                    ForEach(InviteHorizon.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $state.prefs.inviteReviewDaily) {
                    Text("Ask me to RSVP each morning")
                    Text("At the morning summary time, if anything is waiting for a reply.")
                }
                Picker("When a new invite arrives", selection: $state.prefs.newInviteAlert) {
                    ForEach(InviteAlertStyle.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Waiting for a reply") {
                    HStack {
                        Text("\(state.invites.count)").foregroundStyle(.secondary)
                        Button("Review Now") { state.reviewInvites() }.disabled(state.invites.isEmpty)
                    }
                }
            } header: {
                Text("Invitations")
            } footer: {
                Text("Replies go straight to Google or Microsoft 365 for accounts signed in under Accounts; macOS Calendar invites open in Calendar to reply. Turn on the palette next to a calendar (Calendars tab) to pick a colour while you reply.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Preview Alert") { state.previewAlert() }
                    Button("Preview Late Alert") { state.previewLateAlert() }
                        .help("A demo meeting that started a minute ago: watch it get redder, faster and angrier")
                    Button("Preview Meltdown") { state.previewLateAlert(lateBy: 172) }
                        .help("A demo meeting that's nearly three minutes late: watch it start falling apart")
                    Button("Preview Banner") { state.previewAlert(style: .banner) }
                    Button("Preview Notification") { state.previewAlert(style: .notification) }
                }
            } footer: {
                Text("Preview Alert behaves exactly as a real alert would right now. Esc dismisses · Return joins · Snooze re-alerts after a minute.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // Live diagnostic so you can check detection while presenting or on a call.
            while !Task.isCancelled {
                status = SystemContext.describe(SystemContext.current())
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @State private var status = "Checking…"

    private var summaryTime: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: state.prefs.summaryTime / 60, minute: state.prefs.summaryTime % 60, second: 0, of: Date()) ?? Date() },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                state.prefs.summaryTime = (c.hour ?? 8) * 60 + (c.minute ?? 30)
            }
        )
    }
}

private struct GeneralTab: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Countdown panel") {
                Toggle("Show floating countdown", isOn: $state.prefs.showPanel)
                Picker("Style", selection: $state.prefs.panelStyle) {
                    Text("Standard").tag(PanelStyle.standard)
                    Text("Compact").tag(PanelStyle.compact)
                    Text("Mini").tag(PanelStyle.mini)
                }
                Toggle(isOn: $state.prefs.panelGrow) {
                    Text("Grow as meetings approach")
                    Text("One size up 15 minutes before, full size at 5 minutes.")
                }
                .disabled(state.prefs.panelStyle == .standard)
                Picker("Only show when a meeting starts within", selection: $state.prefs.panelWithinMinutes) {
                    Text("Always show").tag(0)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text($0 == 60 ? "1 hour" : "\($0) minutes").tag($0) }
                }
                Toggle("Also show during meetings", isOn: $state.prefs.panelShowDuringMeetings)
                Toggle("Hide when nothing else is on today", isOn: $state.prefs.panelHidesWhenIdle)
                    .disabled(state.prefs.panelWithinMinutes > 0)
                let hidden = state.prefs.panelHiddenMeetings.count + state.prefs.panelHiddenSeries.count
                LabeledContent("Hidden events") {
                    HStack {
                        Text(hidden == 0 ? "None — right-click an event to hide it" : "\(hidden)")
                            .foregroundStyle(.secondary)
                        if hidden > 0 {
                            Button("Show All") {
                                state.prefs.panelHiddenMeetings = []
                                state.prefs.panelHiddenSeries = []
                            }
                        }
                    }
                }
            }
            Section("Meeting notes drawer") {
                Toggle(isOn: $state.prefs.showEnrichmentDrawer) {
                    Text("Show a Notes button during meetings")
                    Text("When an assistant has attached notes, links, a checklist or bingo card, a button at the bottom of the screen slides up into a drawer.")
                }
                Toggle("Open it when the meeting starts", isOn: $state.prefs.enrichmentDrawerAutoOpen)
                    .disabled(!state.prefs.showEnrichmentDrawer)
            }
            Section("Menu bar") {
                Picker("Show", selection: $state.prefs.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Longest title", selection: $state.prefs.menuBarTitleLength) {
                    ForEach([12, 16, 22, 30, 40], id: \.self) { Text("\($0) characters").tag($0) }
                }
                .disabled(state.prefs.menuBarStyle != .full)
                Text("macOS hides menu bar items that don't fit, starting with the leftmost, and apps can't ask to be kept. A narrower style helps; so does ⌘-dragging the Cadence icon to the right, nearer the clock — macOS remembers where you put it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show tomorrow's meetings in the evening", isOn: $state.prefs.tomorrowPreview)
                Picker("From", selection: $state.prefs.tomorrowFromHour) {
                    ForEach([12, 15, 16, 17, 18, 19, 20, 21], id: \.self) { h in
                        Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened)).tag(h)
                    }
                }
                .disabled(!state.prefs.tomorrowPreview)
            }
            Section("Meetings") {
                LabeledContent("Join next meeting") {
                    ShortcutRecorder(spec: $state.prefs.joinHotKey)
                }
                Toggle("Open Zoom and Teams in their apps when installed", isOn: $state.prefs.preferNativeApps)
                Picker("Travel time by", selection: $state.prefs.travelMode) {
                    ForEach(TravelMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription). Move Cadence to /Applications and try again."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Comma-separated minute offsets, e.g. "15, 5, 0".
private struct OffsetsField: View {
    @Binding var offsets: [Int]
    @State private var text = ""

    var body: some View {
        TextField("Remind me", text: $text, prompt: Text("10, 0"))
            .onAppear { text = offsets.map(String.init).joined(separator: ", ") }
            .onChange(of: text) {
                let parsed = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { (0...240).contains($0) }
                offsets = Array(Set(parsed)).sorted(by: >)
            }
    }
}

/// Settings → Alerts → Media remote control: the Mac's media keys drive the phone in desk mode.
private struct MediaRemoteSection: View {
    @Environment(AppState.self) private var state
    @State private var trusted = MediaKeyTap.isTrusted
    @State private var conflicts: [String] = []

    var body: some View {
        @Bindable var state = state
        let on = state.prefs.mediaRemoteControl
        Section {
            Toggle(isOn: Binding(get: { on }, set: { new in
                state.prefs.mediaRemoteControl = new
                if new && !MediaKeyTap.isTrusted { MediaKeyTap.requestAccess() }
            })) {
                Text("Media remote control")
                Text("While your iPhone shows its desk display, the volume, mute, play/pause and skip keys control the iPhone instead. Never during a call.")
            }
            if on && !trusted {
                HStack {
                    Label("Needs Accessibility access to catch the media keys. Until then they work as normal on the Mac.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Settings") { MediaKeyTap.openAccessibilitySettings() }
                }
            }
            Toggle(isOn: $state.prefs.mediaRemotePauseLimitEnabled) {
                Text("Hand the keys back when the iPhone is paused")
                Text("Off: they go to the iPhone for as long as its desk display is up.")
            }
            .disabled(!on)
            if state.prefs.mediaRemotePauseLimitEnabled {
                Stepper(value: $state.prefs.mediaRemotePauseLimitSeconds, in: 5...600, step: 5) {
                    LabeledContent("After paused for") {
                        TextField("", value: $state.prefs.mediaRemotePauseLimitSeconds, format: .number)
                            .frame(width: 48).multilineTextAlignment(.trailing)
                        Text("seconds")
                    }
                }
                .disabled(!on)
            }
            Picker("Mini-player", selection: $state.prefs.mediaHUD) {
                ForEach(MediaHUDMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(!on)
            if on && !conflicts.isEmpty {
                Label("Also catching media keys: \(conflicts.joined(separator: ", ")). Whichever app sees a key first wins, so some keys may not reach the iPhone (or the Mac).",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        } header: { Text("Media remote control") } footer: {
            Text("Track, artwork and skip work with Spotify and Apple Music on the iPhone; other apps get play/pause and volume. The mini-player hides while you present, share your screen or are on a call.")
        }
        .task(id: on) {
            // Access and other apps can change while Settings is open.
            while !Task.isCancelled {
                trusted = MediaKeyTap.isTrusted
                conflicts = on ? MediaKeyTap.conflicts() : []
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
