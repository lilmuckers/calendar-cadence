import CadenceCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            CalendarsTab().tabItem { Label("Calendars", systemImage: "calendar") }
            FiltersTab().tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
            AlertsTab().tabItem { Label("Alerts", systemImage: "bell.badge") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 460)
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
                Text("Cadence reads every account in macOS Calendar. Add Google, Exchange/Outlook, iCloud or CalDAV accounts in System Settings → Internet Accounts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(grouped, id: \.0) { source, calendars in
                Section(source) {
                    ForEach(calendars) { cal in
                        Toggle(isOn: Binding(get: { state.isCalendarEnabled(cal.id) },
                                             set: { state.setCalendar(cal.id, enabled: $0) })) {
                            HStack(spacing: 8) {
                                Circle().fill(Color(cal.color)).frame(width: 10, height: 10)
                                Text(cal.title)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
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
            }
            Section {
                Button("Preview Alert") { state.previewAlert() }
            } footer: {
                Text("Esc dismisses · Return joins · Snooze re-alerts after a minute.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Toggle("Hide when nothing else is on today", isOn: $state.prefs.panelHidesWhenIdle)
            }
            Section("Menu bar") {
                Toggle("Show next meeting title and countdown", isOn: $state.prefs.showMenuBarTitle)
            }
            Section("Meetings") {
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
