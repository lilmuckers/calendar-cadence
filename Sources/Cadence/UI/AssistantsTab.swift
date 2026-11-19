import AppKit
import CadenceCore
import Charts
import SwiftUI
import os

/// Settings → Assistants: set up the local MCP server for AI assistants, and see what they've done.
struct AssistantsTab: View {
    enum Page: String, CaseIterable { case setup = "Setup", activity = "Activity" }
    @State private var page: Page = .setup

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.top, 12)
            switch page {
            case .setup: AssistantSetupView()
            case .activity: AssistantActivityView()
            }
        }
    }
}

// MARK: - Setup

private struct AssistantSetupView: View {
    @Environment(AppState.self) private var state
    @State private var clients = AssistantClients()
    @State private var restartPrompt: AssistantClient?
    @State private var confirmMove = false
    @State private var moveError: String?
    @State private var copied: String?

    private var bridge: MCPBridge? { MCPBridge.current }

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Toggle(isOn: $state.prefs.mcpEnabled) {
                    Text("Let AI assistants on this Mac use Cadence")
                    Text("Assistants can read your merged agenda, invites and clashes, get told when meetings start or change, and — with your OK — reply to invites or join meetings. Cadence only listens on a private socket on this Mac.")
                }
                if state.prefs.mcpEnabled, let bridge {
                    LabeledContent("Status") {
                        if let error = bridge.lastError {
                            Text(error).foregroundStyle(.red)
                        } else if bridge.clients.isEmpty {
                            Text(bridge.running ? "Ready — no assistants connected" : "Starting…").foregroundStyle(.secondary)
                        } else {
                            Text(MCPClientNames.summary(bridge.clients.map(\.name)) + " connected")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            if !AppLocation.isInApplications {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cadence is running from \(Bundle.main.bundleURL.deletingLastPathComponent().path)")
                                .font(.callout.weight(.semibold))
                            Text("Assistants are set up with the path to this copy, so they'll lose Cadence if it moves or is rebuilt. Move it to Applications first for a stable setup.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let moveError { Text(moveError).font(.caption).foregroundStyle(.red) }
                        }
                        Spacer()
                        Button("Move to Applications") { confirmMove = true }
                    }
                }
            }

            Section {
                ForEach(AssistantClient.allCases) { c in
                    ClientRow(client: c, clients: clients, connected: isConnected(c), copied: $copied) {
                        AssistantLog.write("Install tapped: \(c.name)")
                        Task {
                            await clients.install(c)
                            if c.restartsToLoad, clients.status[c]?.running == true, clients.lastError == nil { restartPrompt = c }
                        }
                    }
                }
                if let error = clients.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Other MCP clients") {
                    HStack {
                        Text(MCPBridge.helperPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                        copyButton("Copy path", key: "path", text: MCPBridge.helperPath)
                    }
                }
            } header: {
                Text("Assistants on this Mac")
            } footer: {
                Text("Install adds a \"cadence\" server to the assistant's MCP config and keeps a .cadence-backup of the old file. Claude Code is set up with its own `claude mcp add` command (user scope).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(MCPCatalog.tools.filter(\.isAction), id: \.name) { tool in
                    Toggle(tool.title, isOn: Binding(
                        get: { state.prefs.mcpAutoApprove.contains(tool.name) },
                        set: { on in
                            if on { state.prefs.mcpAutoApprove.insert(tool.name) } else { state.prefs.mcpAutoApprove.remove(tool.name) }
                        }))
                }
            } header: {
                Text("Allow without asking")
            } footer: {
                Text("Otherwise Cadence shows a card to Allow or Deny each action. Unanswered requests are denied after a minute.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $state.prefs.mcpEnrichments) {
                    Text("Let assistants attach things to meetings")
                    Text("Notes, links, checklists, timed agendas, attendee briefs, a decisions log, key numbers and buzzword bingo. Shown during the meeting; what you tick or log, assistants can read back.")
                }
                let count = state.enrichments.book.items.count
                LabeledContent("Attached now") {
                    HStack {
                        Text(count == 0 ? "Nothing" : "\(count)").foregroundStyle(.secondary)
                        if count > 0 {
                            Button("Remove All") { state.enrichments.mutate { $0 = EnrichmentBook() } }
                        }
                    }
                }
            } header: {
                Text("Meeting attachments")
            } footer: {
                Text("These only change what Cadence shows, so they don't ask first. One-off attachments are kept for two weeks after the meeting.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Working hours (for finding free time)") {
                DatePicker("Start", selection: minutes($state.prefs.workStart), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: minutes($state.prefs.workEnd), displayedComponents: .hourAndMinute)
            }
        }
        .formStyle(.grouped)
        .onAppear { clients.refresh() }
        .alert("Restart \(restartPrompt?.name ?? "")?", isPresented: Binding(get: { restartPrompt != nil }, set: { if !$0 { restartPrompt = nil } }),
               presenting: restartPrompt) { c in
            Button("Restart") { Task { await clients.restart(c) } }
            Button("Later", role: .cancel) {}
        } message: { c in
            Text("\(c.name) loads MCP servers when it starts. Restarting closes its windows.")
        }
        .alert("Move Cadence to Applications?", isPresented: $confirmMove) {
            Button("Move and Relaunch") {
                Task {
                    do { try await AppLocation.moveToApplications(clients: clients) } catch { moveError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cadence copies itself to /Applications (replacing any copy there), updates assistants you've set up, and relaunches from there.")
        }
    }

    private func isConnected(_ c: AssistantClient) -> Bool {
        bridge?.clients.contains { c.matches(clientName: $0.name) } ?? false
    }

    private func copyButton(_ title: String, key: String, text: String) -> some View {
        Button(copied == key ? "Copied ✓" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == key { copied = nil } }
        }
    }

    /// Minutes after midnight as a time-of-day Date.
    private func minutes(_ binding: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(binding.wrappedValue) * 60) },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                binding.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

private struct ClientRow: View {
    let client: AssistantClient
    let clients: AssistantClients
    let connected: Bool
    @Binding var copied: String?
    let install: () -> Void
    @State private var showManual = false

    var body: some View {
        let s = clients.status[client] ?? AssistantClientStatus()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                icon.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(client.name).font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 4) {
                        if !s.installed {
                            chip("Not found", .secondary)
                        } else if client.bundleID != nil {
                            chip(s.running ? "Running" : "Not running", s.running ? .blue : .secondary)
                        }
                        switch s.config {
                        case .current: chip("Set up", .green)
                        case .stale: chip("Points at another copy", .orange)
                        case .missing: EmptyView()
                        }
                        if connected { chip("Connected now", .purple) }
                    }
                }
                Spacer()
                if clients.busy.contains(client) {
                    ProgressView().controlSize(.small)
                } else {
                    actions(s)
                }
            }
            if let problem = s.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if case .stale(let path) = s.config {
                Text("Configured for \(path)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            DisclosureGroup(client == .claudeCode ? "Command" : "Config", isExpanded: $showManual) {
                let text = client.manualSetup(helper: clients.helperPath)
                HStack(alignment: .top) {
                    Text(text).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied == client.id ? "Copied ✓" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = client.id
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.05)))
                if client != .claudeCode {
                    Text(client.configURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func actions(_ s: AssistantClientStatus) -> some View {
        let canInstall = s.problem == nil && (s.installed || client != .claudeCode)
        HStack(spacing: 6) {
            switch s.config {
            case .missing:
                Button("Install", action: install).disabled(!canInstall)
            case .stale:
                Button("Update", action: install).disabled(!canInstall)
                Button("Remove") { Task { await clients.remove(client) } }
            case .current:
                if client.restartsToLoad && s.running && !connected {
                    Button("Restart") { Task { await clients.restart(client) } }
                        .help("\(client.name) loads MCP servers when it starts")
                }
                Button("Remove") { Task { await clients.remove(client) } }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let url = clients.appURL(client) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else if client == .claudeCode {
            Image(systemName: "terminal.fill").font(.system(size: 15)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.85, green: 0.47, blue: 0.34).gradient))
        } else {
            Image(systemName: "app.dashed").font(.system(size: 20)).foregroundStyle(.tertiary)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

// MARK: - Activity

private struct AssistantActivityView: View {
    @State private var clientFilter: String?
    @State private var confirmClear = false

    private var store: MCPActivityStore? { MCPBridge.current?.activity }

    var body: some View {
        let entries = store?.entries ?? []
        let now = Date()
        let stats = MCPActivity.stats(entries, now: now, client: clientFilter)
        let clientNames = Array(Set(entries.compactMap { $0.kind == .call ? $0.client : nil })).sorted()
        let recent = entries.reversed().filter {
            $0.kind == .call && !$0.isWait && (clientFilter == nil || $0.client == clientFilter)
        }.prefix(50)

        Form {
            Section {
                HStack(spacing: 10) {
                    tile("\(stats.callsToday)", "calls today", "bolt.fill", .blue)
                    tile("\(stats.callsWeek)", "last 7 days", "calendar", .teal)
                    tile("\(stats.actionsAllowed + stats.actionsAuto)", "actions done", "checkmark.circle.fill", .green)
                    tile("\(stats.actionsDenied)", "denied", "hand.raised.fill", .red)
                }
                .padding(.vertical, 4)
                if clientNames.count > 1 {
                    Picker("Assistant", selection: $clientFilter) {
                        Text("All").tag(String?.none)
                        ForEach(clientNames, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
            }

            if entries.isEmpty {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.title2).foregroundStyle(.purple)
                        Text("No assistant activity yet").font(.headline)
                        Text("Once an assistant uses Cadence, you'll see what it asked for and did here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else {
                Section("Last 7 days") {
                    Chart(stats.perDay, id: \.day) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Calls", d.count))
                            .foregroundStyle(Color.blue.gradient)
                            .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) }
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 90)
                    HStack(spacing: 14) {
                        footnote("\(stats.sessionsWeek) sessions", "person.wave.2")
                        footnote("\(stats.eventsWeek) events sent", "bell")
                        if stats.waitsWeek > 0 { footnote("\(stats.waitsWeek) event waits", "hourglass") }
                        if stats.errorsWeek > 0 { footnote("\(stats.errorsWeek) errors", "exclamationmark.triangle") }
                    }
                }

                if !stats.perTool.isEmpty {
                    Section("By tool") {
                        Chart(stats.perTool, id: \.tool) { t in
                            BarMark(x: .value("Calls", t.count), y: .value("Tool", MCPCatalog.tool(t.tool)?.title ?? t.tool))
                                .foregroundStyle(by: .value("Kind", t.isAction ? "Action" : "Read"))
                                .cornerRadius(3)
                                .annotation(position: .trailing) { Text("\(t.count)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .chartForegroundStyleScale(["Read": Color.blue, "Action": Color.purple])
                        .chartLegend(position: .top, alignment: .trailing)
                        .frame(height: CGFloat(max(2, stats.perTool.count)) * 24 + 30)
                    }
                }

                Section {
                    ForEach(Array(recent)) { e in ActivityRow(entry: e) }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear History…") { confirmClear = true }
                            .buttonStyle(.link).font(.caption)
                    }
                } footer: {
                    Text("Kept on this Mac for 30 days. Event waits (assistants listening for updates) aren't listed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Clear assistant activity?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { store?.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the activity history. It can't be undone.")
        }
    }

    private func tile(_ value: String, _ label: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.08)))
    }

    private func footnote(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
    }
}

private struct ActivityRow: View {
    let entry: MCPActivityEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isAction == true ? "wand.and.stars" : "eye")
                .font(.system(size: 11))
                .foregroundStyle(entry.isAction == true ? .purple : .blue)
                .frame(width: 22, height: 22)
                .background(Circle().fill((entry.isAction == true ? Color.purple : Color.blue).opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(MCPCatalog.tool(entry.tool ?? "")?.title ?? entry.tool ?? "?").font(.system(size: 12, weight: .semibold))
                    Text("· \(entry.client ?? "?")").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            outcome
            Text(entry.at, format: Calendar.current.isDateInToday(entry.at) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())
                .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                .frame(minWidth: 60, alignment: .trailing)
        }
    }

    @ViewBuilder private var outcome: some View {
        switch entry.outcome {
        case .ok: pill("✓", .green)
        case .autoApproved: pill("auto", .teal)
        case .denied: pill("denied", .red)
        case .timedOut: pill("no answer", .orange)
        case .error: pill("error", .orange)
        case nil: EmptyView()
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}
