import CadenceCore
import Foundation

/// Enrichments: assistants attach them over MCP; the user ticks and logs in the drawer or on the phone.
extension AppState {
    func enrichments(for m: Meeting) -> [Enrichment] { enrichments.enrichments(for: m) }

    func enrichmentState(_ e: Enrichment, _ m: Meeting) -> EnrichmentState { enrichments.state(e, m) }

    /// The meeting the drawer is for: the live one with enrichments (latest started), else one starting
    /// within `leadMinutes`.
    func enrichmentFocus(leadMinutes: Double = 5) -> Meeting? {
        let candidates = activeMeetings.filter { !$0.isAllDay && !$0.isCanceled && !enrichments(for: $0).isEmpty }
        if let live = candidates.filter({ $0.isInProgress(at: now) }).max(by: { $0.start < $1.start }) { return live }
        return candidates.first { $0.start > now && $0.start.timeIntervalSince(now) <= leadMinutes * 60 }
    }

    /// Runs an enrichment MCP tool.
    func enrichmentTool(_ name: String, _ arguments: [String: JSONValue], client: String) throws -> JSONValue {
        if name != "get_enrichments", !prefs.mcpEnrichments {
            throw MCPToolError("The user turned off assistant attachments in Cadence (Settings → Assistants).", kind: .denied)
        }
        // Enrichments on meetings from calendars hidden from assistants are out of reach by id too.
        if let id = arguments["enrichment_id"]?.stringValue, let e = enrichments.book.enrichment(id: id),
           let m = (meetings + allMeetings + invites).first(where: { $0.id == e.meetingID }), isHiddenFromAssistants(m) {
            throw MCPToolError("No enrichment with id \(id). Get ids from get_enrichments.")
        }
        let outcome = try enrichments.mutate { book in
            try EnrichmentTools.call(name, arguments, book: &book, meeting: { id in
                guard let m = (self.meetings + self.allMeetings + self.invites).first(where: { $0.id == id }),
                      !self.isHiddenFromAssistants(m) else {
                    throw MCPToolError("No meeting with id \(id). Get ids from get_agenda or get_next_meeting.")
                }
                return m
            }, client: MCPClientNames.display(client))
        }
        if outcome.changed { enrichmentsChanged() }
        return outcome.result
    }

    /// The user ticked, marked or logged something (here or on the phone).
    func applyEnrichment(_ action: EnrichmentAction, meetingID: String) {
        guard let m = meeting(id: meetingID), let e = enrichments.book.enrichment(id: action.enrichmentID) else { return }
        let before = enrichments.state(e, m)
        guard let after = enrichments.mutate({ $0.apply(action, meetingID: m.id) }) else { return }
        enrichmentsChanged()
        emit(EnrichmentTools.event(for: action, enrichment: e, before: before, after: after, meeting: m), about: [m])
    }

    private func enrichmentsChanged() {
        companion.pushSnapshot()
    }
}
