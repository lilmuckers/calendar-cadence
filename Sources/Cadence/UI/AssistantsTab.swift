import AppKit
import CadenceCore
import SwiftUI

/// Settings → Assistants: the local MCP server for AI assistants (Claude, Cursor…).
struct AssistantsTab: View {
    @Environment(AppState.self) private var state
    @State private var copied: String?

    private var bridge: MCPBridge? { MCPBridge.current }

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Toggle(isOn: $state.prefs.mcpEnabled) {
                    Text("Let AI assistants on this Mac use Cadence")
                    Text("Assistants such as Claude can read your merged agenda, invites and clashes, get told when meetings start or change, and — with your OK — reply to invites or join meetings. Nothing leaves this Mac except through the assistant you connect.")
                }
                if state.prefs.mcpEnabled, let bridge {
                    LabeledContent("Status") {
                        if let error = bridge.lastError {
                            Text(error).foregroundStyle(.red)
                        } else if bridge.clients.isEmpty {
                            Text(bridge.running ? "Ready — no assistants connected" : "Starting…").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(bridge.clients) { c in
                                    Label("\(c.name) · since \(c.connectedAt.formatted(date: .omitted, time: .shortened))",
                                          systemImage: "sparkles")
                                }
                            }
                        }
                    }
                }
            }

            Section("Connect an assistant") {
                LabeledContent("Claude Code") {
                    copyButton("Copy command", key: "code", text: claudeCodeCommand)
                }
                LabeledContent("Claude Desktop") {
                    HStack {
                        copyButton("Copy config", key: "desktop", text: claudeDesktopConfig)
                        Button("Open config folder") {
                            let dir = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Library/Application Support/Claude")
                            NSWorkspace.shared.open(dir)
                        }
                    }
                }
                LabeledContent("Other MCP clients") {
                    copyButton("Copy path", key: "path", text: MCPBridge.helperPath)
                }
                Text("Run the command in Terminal, or paste the config into claude_desktop_config.json (merge with any existing \"mcpServers\") and restart Claude. Other clients: add a stdio server whose command is the path above.")
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

            Section("Working hours (for finding free time)") {
                DatePicker("Start", selection: minutes($state.prefs.workStart), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: minutes($state.prefs.workEnd), displayedComponents: .hourAndMinute)
            }
        }
        .formStyle(.grouped)
    }

    private func copyButton(_ title: String, key: String, text: String) -> some View {
        Button(copied == key ? "Copied ✓" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == key { copied = nil } }
        }
    }

    private var claudeCodeCommand: String {
        "claude mcp add --scope user cadence -- \"\(MCPBridge.helperPath)\""
    }

    private var claudeDesktopConfig: String {
        let path = MCPBridge.helperPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "cadence": {
              "command": "\(path)"
            }
          }
        }
        """
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
