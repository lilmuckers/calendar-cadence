import CadenceCore
import SwiftUI

/// Settings → Browser: which profile of the default browser opens which meeting.
struct BrowserTab: View {
    @Environment(AppState.self) private var state
    @State private var newDomain = ""
    @State private var newDomainProfile = ""
    @State private var newContainer = ""
    @State private var newContainerProfile = ""

    /// Services Cadence can open in their own app (see `MeetingLink.nativeURL`).
    private static let nativeServices: [MeetingService] = [.zoom, .teams]

    var body: some View {
        @Bindable var state = state
        let store = state.browsers
        Form {
            Section {
                HStack(spacing: 10) {
                    if let icon = store.icon {
                        Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default browser: \(store.defaultBrowserName.isEmpty ? "Unknown" : store.defaultBrowserName)")
                        Text(summary(store))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if store.supportsProfiles {
                Section {
                    ForEach(store.profiles) { p in
                        LabeledContent(p.title) {
                            Text(p.email ?? (p.container != nil ? "Container" : "Not signed in"))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Profiles")
                } footer: {
                    Text("Pick a profile per account or calendar in the Calendars tab, add organiser rules below, or right-click Join → Join in.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Open Zoom and Teams in their apps when installed", isOn: $state.prefs.preferNativeApps)
                    ForEach(Self.nativeServices, id: \.self) { service in
                        Toggle(isOn: Binding(
                            get: { state.prefs.profileRules.nativeOverride.contains(service) },
                            set: { on in
                                if on { state.prefs.profileRules.nativeOverride.insert(service) }
                                else { state.prefs.profileRules.nativeOverride.remove(service) }
                            })) {
                            Text("\(service.displayName): use the profile instead of the app")
                        }
                        .disabled(!state.prefs.preferNativeApps)
                    }
                } header: {
                    Text("Native apps")
                } footer: {
                    Text("When a meeting has a profile assigned, these services open in that profile even though their app is installed. Useful for Teams, whose app can't switch tenant per link.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(state.prefs.profileRules.domains) { rule in
                        HStack {
                            Text("@\(rule.domain)")
                            Spacer()
                            Picker("", selection: Binding(
                                get: { rule.profileID },
                                set: { id in
                                    if let i = state.prefs.profileRules.domains.firstIndex(where: { $0.id == rule.id }) {
                                        state.prefs.profileRules.domains[i].profileID = id
                                    }
                                })) {
                                profileOptions(store, current: rule.profileID)
                            }
                            .labelsHidden()
                            .frame(width: 200)
                            Button {
                                state.prefs.profileRules.domains.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove rule")
                        }
                    }
                    .onMove { state.prefs.profileRules.domains.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField("clientname.com", text: $newDomain)
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: $newDomainProfile) {
                            Text("Choose profile").tag("")
                            ForEach(store.profiles) { Text($0.title).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        Button("Add") {
                            let domain = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
                                .replacingOccurrences(of: "@", with: "")
                            state.prefs.profileRules.domains.append(DomainProfileRule(domain: domain, profileID: newDomainProfile))
                            newDomain = ""
                        }
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty || newDomainProfile.isEmpty)
                    }
                } header: {
                    Text("Organiser rules")
                } footer: {
                    Text("Meetings organised by someone at this domain (or a subdomain) open in the chosen profile — handy when client invites land in your main calendar. These beat calendar and account choices; the first matching rule wins.")
                        .foregroundStyle(.secondary)
                }

                if store.defaultBrowser == .firefox {
                    containersSection(store)
                }

                let rules = state.prefs.profileRules
                if !rules.meetings.isEmpty || !rules.series.isEmpty {
                    Section("Remembered choices") {
                        LabeledContent("From Join in") {
                            HStack {
                                Text("\(rules.series.count) series · \(rules.meetings.count) single meetings")
                                Button("Forget All") {
                                    state.prefs.profileRules.series = [:]
                                    state.prefs.profileRules.meetings = [:]
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.browsers.refresh() }
    }

    @ViewBuilder private func containersSection(_ store: BrowserProfileStore) -> some View {
        Section {
            ForEach(state.prefs.profileRules.firefoxContainers) { c in
                HStack {
                    Text(c.name)
                    Spacer()
                    Text(store.profiles.first { $0.directory == c.profileDirectory && $0.container == nil }?.name ?? "Missing profile")
                        .foregroundStyle(.secondary)
                    Button {
                        state.prefs.profileRules.firefoxContainers.removeAll { $0.id == c.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove container")
                }
            }
            HStack {
                TextField("Container name", text: $newContainer)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $newContainerProfile) {
                    Text("In profile").tag("")
                    ForEach(store.profiles.filter { $0.container == nil }) { Text($0.name).tag($0.directory) }
                }
                .labelsHidden()
                .frame(width: 180)
                Button("Add") {
                    state.prefs.profileRules.firefoxContainers.append(
                        FirefoxContainer(profileDirectory: newContainerProfile, name: newContainer.trimmingCharacters(in: .whitespaces)))
                    newContainer = ""
                }
                .disabled(newContainer.trimmingCharacters(in: .whitespaces).isEmpty || newContainerProfile.isEmpty)
            }
        } header: {
            Text("Firefox containers")
        } footer: {
            Text("Needs the “Open external links in a container” add-on. Each container you add here can be picked like a profile.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func profileOptions(_ store: BrowserProfileStore, current: String) -> some View {
        ForEach(store.profiles) { Text($0.title).tag($0.id) }
        if store.profile(id: current) == nil {
            Text("Unavailable profile").tag(current)
        }
    }

    private func summary(_ store: BrowserProfileStore) -> String {
        guard let browser = store.defaultBrowser else {
            return "Meeting links open in it as usual. Choosing a profile per meeting needs Chrome, Edge, Brave, Vivaldi or Firefox as the default browser."
        }
        if store.profiles.isEmpty { return "No \(browser.displayName) profiles found." }
        return "\(store.profiles.count) profiles. Rules for other browsers are kept but ignored until you switch back."
    }
}

/// Picker content shared by the Calendars tab: "Default" plus each profile.
struct ProfilePickerOptions: View {
    let store: BrowserProfileStore
    let noneLabel: String
    let current: String?

    var body: some View {
        Text(noneLabel).tag(String?.none)
        ForEach(store.profiles) { p in
            Text(p.title).tag(Optional(p.id))
        }
        if let current, store.profile(id: current) == nil {
            Text("Unavailable profile").tag(Optional(current))
        }
    }
}
