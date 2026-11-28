import CadenceCore
import ServiceManagement
import SwiftUI

/// The tabs of Settings, so other windows (setup's "When you're ready" rows) can open one.
enum SettingsTab: Hashable {
    case general, accounts, calendars, filters, alerts, messages, work, phone, browser, assistants
}

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        // General first (macOS convention), then where events come from, what happens before
        // meetings, and the integrations.
        TabView(selection: $state.settingsTab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag(SettingsTab.accounts)
            CalendarsTab().tabItem { Label("Calendars", systemImage: "calendar") }.tag(SettingsTab.calendars)
            FiltersTab().tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }.tag(SettingsTab.filters)
            AlertsTab().tabItem { Label("Alerts", systemImage: "bell.badge") }.tag(SettingsTab.alerts)
            MessagesTab().tabItem { Label("Messages", systemImage: "paperplane") }.tag(SettingsTab.messages)
            WorkTab().tabItem { Label("Work", systemImage: "briefcase") }.tag(SettingsTab.work)
            PhoneTab().tabItem { Label("iPhone", systemImage: "iphone") }.tag(SettingsTab.phone)
            BrowserTab().tabItem { Label("Browser", systemImage: "globe") }.tag(SettingsTab.browser)
            AssistantsTab().tabItem { Label("Assistants", systemImage: "sparkles") }.tag(SettingsTab.assistants)
        }
        .frame(width: 680, height: 560)
    }
}

private struct WorkTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            WorkScheduleEditor(schedule: $state.prefs.workSchedule,
                               defencesFooter: "Nudges and break questions also go to your paired iPhone. A meeting over a break asks like a double-booking: keep the break (the meeting won't alert) or give it up for the day.")
            Section {
                Toggle("Show how the day's going in the menu", isOn: $state.prefs.dayMoments)
                Toggle("Sum up the day when work ends", isOn: $state.prefs.dayWrapNotification)
            } header: {
                Text("Your day")
            } footer: {
                Text("The menu shows a coffee before work, focus time and how long it's clear for, your breaks, and a wave at the end of the day. The sum-up is a notification with the day's meetings and focus time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!state.prefs.workSchedule.enabled)
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
        @Bindable var state = state
        Form {
            if state.access != .granted {
                Section {
                    LabeledContent("Cadence needs calendar access to read your events.") {
                        Button("Open Privacy Settings", action: state.openPrivacySettings)
                    }
                }
            }
            Section {
                Toggle(isOn: $state.prefs.useEventColors) {
                    Text("Use event colours")
                    Text("Events coloured individually in Google Calendar (or with a colour in an ICS feed) use that colour instead of their calendar's. Google event colours need the direct Google sign-in; macOS Calendar doesn't pass them on.")
                }
                Toggle(isOn: $state.prefs.namedColorsOnly) {
                    Text("Only offer named colours")
                    Text("When picking a colour for a Google event, show just the colours you've named in Google Calendar, hiding the stock and unnamed custom ones. Calendars with no named colours still show them all.")
                }
            } header: {
                Text("Colours")
            }
            Section {
                legendRow("paintpalette", "Ask for a colour when you reply to an invite on this calendar")
                legendRow("bell.slash", "Agenda only: events still show, but never alert, remind, clash or count as your current or next meeting")
                legendRow("sparkles", "Hide from assistants: AI assistants connected over MCP can't see this calendar or its events")
                if state.browsers.supportsProfiles {
                    legendRow("globe", "Open this calendar's meeting links in a different \(state.browsers.defaultBrowserName) profile")
                }
            } header: {
                Text("Your calendars")
            } footer: {
                Text("Switch calendars on or off below; the icons on each row do the rest. Add sources in the Accounts tab.")
                    .foregroundStyle(.secondary)
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
                                let unshared = state.isCalendarHiddenFromAssistants(cal.id)
                                Button {
                                    state.setCalendar(cal.id, hiddenFromAssistants: !unshared)
                                } label: {
                                    Image(systemName: unshared ? "lock.fill" : "sparkles")
                                        .foregroundStyle(unshared ? Color.purple : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(unshared ? "Hidden from assistants: connected AI assistants can't see this calendar or its events. Click to share it again."
                                               : "Hide from assistants: keep this calendar and its events away from AI assistants connected over MCP")
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

    /// What one of the per-calendar row icons does.
    private func legendRow(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
        }
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
                    // Reads as "Hide: events shorter than…", like the toggles above.
                    Text(state.prefs.filters.minimumDurationMinutes == 0
                         ? "Short events: off"
                         : "Events shorter than \(state.prefs.filters.minimumDurationMinutes) min")
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
            Section {
                Toggle("Take over the screen before meetings", isOn: $state.prefs.takeoverEnabled)
                Group {
                    Picker("Show", selection: $state.prefs.takeoverLeadSeconds) {
                        Text("10 seconds before").tag(10.0)
                        Text("30 seconds before").tag(30.0)
                        Text("1 minute before").tag(60.0)
                        Text("2 minutes before").tag(120.0)
                        Text("5 minutes before").tag(300.0)
                    }
                    Toggle("Cover all displays", isOn: $state.prefs.takeoverAllScreens)
                    Toggle("Only for meetings with a join link", isOn: $state.prefs.takeoverOnlyWithLink)
                    Toggle("Play sound", isOn: $state.prefs.takeoverSound)
                    Picker(selection: $state.prefs.takeoverAutoDismissMinutes) {
                        Text("1 minute after the start").tag(1)
                        Text("2 minutes after the start").tag(2)
                        Text("5 minutes after the start").tag(5)
                        Text("10 minutes after the start").tag(10)
                        Text("Never — stay until I act").tag(0)
                    } label: {
                        Text("If ignored, close")
                        Text("It gets redder and more frantic for the first 3 minutes you're late.")
                    }
                }
                .disabled(!state.prefs.takeoverEnabled)
            } header: {
                Text("Full-screen alert")
            } footer: {
                Text("Esc dismisses · Return joins · Snooze re-alerts after a minute.")
                    .foregroundStyle(.secondary)
            }
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
                Toggle("Fade out music for meetings", isOn: $state.prefs.fadeMediaForAlerts)
                Toggle("Say which meeting it is", isOn: $state.prefs.announceAlerts)
                    .disabled(!state.prefs.fadeMediaForAlerts)
                LabeledContent("Try it") {
                    Button("Test Fade") { state.onTestMediaFade?() }
                }
            } header: { Text("Music") } footer: {
                Text("Works with Music and Spotify (macOS asks once to let Cadence control them). The voice is your Spoken Content system voice.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Full screen")
                    Spacer()
                    Button("Alert") { state.previewAlert() }
                        .help("Behaves exactly as a real alert would right now")
                    Button("Late") { state.previewLateAlert() }
                        .help("A demo meeting that started a minute ago: watch it get redder, faster and angrier")
                    Button("Meltdown") { state.previewLateAlert(lateBy: 172) }
                        .help("A demo meeting that's nearly three minutes late: watch it start falling apart")
                }
                HStack {
                    Text("Quieter styles")
                    Spacer()
                    Button("Banner") { state.previewAlert(style: .banner) }
                    Button("Notification") { state.previewAlert(style: .notification) }
                }
            } header: {
                Text("Preview")
            } footer: {
                Text("The full-screen preview behaves exactly as a real alert would right now, presenting and call rules included.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Heads-up notification", isOn: $state.prefs.headsUpEnabled)
                Stepper(value: $state.prefs.headsUpMinutes, in: 1...60) {
                    Text("\(state.prefs.headsUpMinutes) min before")
                }
                .disabled(!state.prefs.headsUpEnabled)
                Toggle(isOn: $state.prefs.wrapUpEnabled) {
                    Text("Wrap-up nudge before meetings end")
                    Text("Names the next meeting when one starts straight after. For online meetings, only while your mic is still in use.")
                }
                Group {
                    Stepper(value: $state.prefs.wrapUpMinutes, in: 1...30) {
                        Text("\(state.prefs.wrapUpMinutes) min before the end")
                    }
                    Toggle("Only when another meeting follows", isOn: $state.prefs.wrapUpOnlyBackToBack)
                }
                .disabled(!state.prefs.wrapUpEnabled)
            } header: {
                Text("Reminders")
            }
            Section {
                Toggle("\"Leave now\" reminders", isOn: $state.prefs.leaveEnabled)
                Group {
                    OffsetsField(offsets: $state.prefs.leaveOffsets)
                    Picker("Travel time by", selection: $state.prefs.travelMode) {
                        ForEach(TravelMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                }
                .disabled(!state.prefs.leaveEnabled)
            } header: {
                Text("In-person meetings")
            } footer: {
                Text("Reminders count back from when you need to leave, using live travel time that's re-checked for traffic every 15 minutes. Travel time is also what the agenda's \"leave in…\" hint uses.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Ask which meeting to alert for when two clash", isOn: $state.prefs.clashPromptEnabled)
                LabeledContent("Saved choices") {
                    HStack {
                        Text(state.clashChoices.isEmpty ? "None — right-click a clashing event to choose" : "\(state.clashChoices.count)")
                            .foregroundStyle(.secondary)
                        if !state.clashChoices.isEmpty {
                            Button("Reset") { state.resetClashChoices() }
                                .help("Alert for every clashing meeting and ask again")
                        }
                    }
                }
            } header: {
                Text("Clashes")
            }
            Section {
                Toggle("Morning summary", isOn: $state.prefs.summaryEnabled)
                DatePicker("Send at", selection: summaryTime, displayedComponents: .hourAndMinute)
                    .disabled(!state.prefs.summaryEnabled && !state.prefs.inviteReviewDaily)
                Toggle(isOn: $state.prefs.inviteReviewDaily) {
                    Text("Ask me to RSVP each morning")
                    Text("At the same time, if anything is waiting for a reply.")
                }
            } header: {
                Text("Each morning")
            }
            Section {
                Picker("Look for invites", selection: $state.prefs.inviteHorizon) {
                    ForEach(InviteHorizon.allCases, id: \.self) { Text($0.label).tag($0) }
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
    @State private var canUndoImport = SettingsTransfer.beforeLastImport != nil

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Countdown panel") {
                Toggle("Show floating countdown", isOn: $state.prefs.showPanel)
                Group {
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
                }
                .disabled(!state.prefs.showPanel)
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
            Section {
                Picker("Show", selection: $state.prefs.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Longest title", selection: $state.prefs.menuBarTitleLength) {
                    ForEach([12, 16, 22, 30, 40], id: \.self) { Text("\($0) characters").tag($0) }
                }
                .disabled(state.prefs.menuBarStyle != .full)
                Toggle("Show tomorrow's meetings in the evening", isOn: $state.prefs.tomorrowPreview)
                Picker("From", selection: $state.prefs.tomorrowFromHour) {
                    ForEach([12, 15, 16, 17, 18, 19, 20, 21], id: \.self) { h in
                        Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened)).tag(h)
                    }
                }
                .disabled(!state.prefs.tomorrowPreview)
            } header: {
                Text("Menu bar")
            } footer: {
                Text("macOS hides menu bar items that don't fit, starting with the leftmost, and apps can't ask to be kept. A narrower style helps; so does ⌘-dragging the Cadence icon to the right, nearer the clock — macOS remembers where you put it.")
                    .foregroundStyle(.secondary)
            }
            Section("Joining meetings") {
                LabeledContent("Join next meeting") {
                    ShortcutRecorder(spec: $state.prefs.joinHotKey)
                }
                Toggle("Open Zoom and Teams in their apps when installed", isOn: $state.prefs.preferNativeApps)
            }
            UpdatesSection()
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle(isOn: $state.prefs.restartAfterCrash) {
                    Text("Restart Cadence if it crashes")
                    Text("Reopens it straight away, unless it crashes \(CrashLoopGuard.limit) times within a few minutes. Either way, it shows what went wrong next time it opens, with a button to report it on GitHub.")
                }
                LabeledContent {
                    Button("Run Setup Again…") { state.onRunSetup?() }
                } label: {
                    Text("Setup assistant")
                    Text("Walks through setup with your current choices filled in. Nothing is reset.")
                }
            }
            Section {
                HStack {
                    Button("Export Settings…") { SettingsTransfer.export(state) }
                    Button("Import Settings…") {
                        SettingsTransfer.chooseAndImport(state)
                        canUndoImport = SettingsTransfer.beforeLastImport != nil
                    }
                    Spacer()
                    if canUndoImport {
                        Button("Undo Import") {
                            SettingsTransfer.undoImport(state)
                            canUndoImport = false
                        }
                        .help("Put back the settings you had before the last import")
                    }
                }
            } header: {
                Text("Settings file")
            } footer: {
                Text("A .\(SettingsArchive.fileExtension) file (YAML) with everything in Settings, to back up or copy to another Mac. Accounts, sign-ins and paired iPhones aren't included; subscribed calendar links only if you choose.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { canUndoImport = SettingsTransfer.beforeLastImport != nil }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = LoginItem.set(on)
        if loginError != nil { launchAtLogin = LoginItem.isEnabled }
    }
}

/// "Leave now" reminder times as readable rows ("10 minutes before leaving", "When it's time to
/// leave"), each removable, plus a menu of preset times to add. Stored as minute offsets, e.g. `[10, 0]`.
private struct OffsetsField: View {
    @Binding var offsets: [Int]

    var body: some View {
        let current = LeaveOffsets.normalized(offsets)
        let addable = LeaveOffsets.available(excluding: current)
        LabeledContent("Remind me") {
            Menu {
                ForEach(addable, id: \.self) { minutes in
                    Button(LeaveOffsets.label(minutes)) {
                        offsets = LeaveOffsets.normalized(current + [minutes])
                    }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .fixedSize()
            .disabled(addable.isEmpty)
            .help("Add another reminder time")
        }
        if current.isEmpty {
            Text("No reminders. Add a time to be told when to leave.")
                .foregroundStyle(.secondary)
        }
        ForEach(current, id: \.self) { minutes in
            HStack {
                Label(LeaveOffsets.label(minutes), systemImage: minutes == 0 ? "figure.walk" : "bell")
                Spacer()
                Button {
                    offsets = current.filter { $0 != minutes }
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this reminder")
            }
        }
    }
}

/// Settings → iPhone → Music: share this Mac's music with the phone, and let the Mac's media keys
/// drive the phone in desk mode.
struct PhoneMediaSection: View {
    @Environment(AppState.self) private var state
    @State private var trusted = MediaKeyTap.isTrusted
    @State private var conflicts: [String] = []

    var body: some View {
        @Bindable var state = state
        let on = state.prefs.mediaRemoteControl
        Section {
            Toggle(isOn: $state.prefs.shareMediaWithPhone) {
                Text("Share music with your iPhone")
                Text("Shows this Mac's Music or Spotify on the iPhone's desk display, with play, pause and skip.")
            }
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
            Toggle("Compact until the pointer's over it", isOn: $state.prefs.mediaHUDCompact)
                .disabled(!on || state.prefs.mediaHUD == .never)
            if on && !conflicts.isEmpty {
                Label("Also catching media keys: \(conflicts.joined(separator: ", ")). Whichever app sees a key first wins, so some keys may not reach the iPhone (or the Mac).",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        } header: { Text("Music") } footer: {
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

/// Settings → General → Updates.
private struct UpdatesSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let updater = state.updater
        let mode = Binding(get: { state.prefs.updateMode ?? .off }, set: { state.prefs.updateMode = $0 })
        Section {
            Picker("Updates", selection: mode) {
                ForEach(UpdateMode.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Cadence \(updater.currentVersionText)") {
                HStack {
                    status(updater)
                    Button("Check Now") { Task { await updater.check() } }
                        .disabled(updater.phase == .checking || updater.phase == .downloading || updater.phase == .installing)
                }
            }
            if let release = updater.available {
                LabeledContent("Version \(release.version?.description ?? release.tag) is available") {
                    HStack {
                        Button("What's New") { updater.showNotes() }
                        Button(updater.canInstall ? "Update and Restart" : "Download…") { updater.installAvailable() }
                            .disabled(updater.phase == .downloading || updater.phase == .installing)
                    }
                }
                if let reason = updater.cannotInstallReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text((state.prefs.updateMode ?? .off).detail + " Updates come from Cadence's GitHub releases and are checked against their checksum and Developer ID signature before they're installed.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func status(_ updater: Updater) -> some View {
        Group {
            switch updater.phase {
            case .checking: Text("Checking…")
            case .downloading: Text("Downloading…")
            case .installing: Text("Restarting…")
            case .ready: Text("Ready — installs at a quiet moment")
            case .failed(let message): Text(message).foregroundStyle(.red).lineLimit(2)
            case .idle:
                if updater.available != nil {
                    Text("Update available")
                } else if let checked = updater.lastChecked {
                    Text("Up to date · checked \(checked.formatted(.relative(presentation: .named)))")
                } else {
                    Text("Not checked yet")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
