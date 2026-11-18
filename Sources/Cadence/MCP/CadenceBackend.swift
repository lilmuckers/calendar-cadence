import AppKit
import CadenceCore
import Foundation

/// Answers MCP tool calls and resource reads from the live AppState.
@MainActor
final class CadenceBackend: MCPBackend {
    private let state: AppState
    private let approvals: ApprovalController
    private let activity: MCPActivityStore

    init(state: AppState, approvals: ApprovalController, activity: MCPActivityStore) {
        self.state = state
        self.approvals = approvals
        self.activity = activity
    }

    func record(_ entry: MCPActivityEntry) async { activity.add(entry) }

    // MARK: Tools

    func callTool(_ name: String, arguments a: [String: JSONValue], client: String) async throws -> JSONValue {
        switch name {
        case "get_agenda": return try agenda(a)
        case "get_next_meeting":
            guard let next = state.next else { return ["meeting": .null, "note": "No upcoming meetings in the next two days."] }
            return ["meeting": detailed(next)]
        case "get_current_meeting":
            return ["meetings": .array(state.current.map(detailed))]
        case "list_invites":
            let horizon = a["horizon"]?.stringValue.flatMap(InviteHorizon.init(rawValue:)) ?? state.prefs.inviteHorizon
            let list = InvitePlanner.pending(state.invites, now: Date(), horizon: horizon)
            return ["invites": .array(list.map(state.dto)), "horizon": .string(state.prefs.inviteHorizon.rawValue)]
        case "list_clashes": return clashes()
        case "find_free_time": return try freeTime(a)
        case "list_calendars":
            return ["calendars": .array(state.calendars.map { c in
                ["id": .string(c.id), "title": .string(c.title), "source": .string(c.sourceTitle),
                 "type": .string(c.kind.rawValue), "enabled": .bool(state.isCalendarEnabled(c.id))]
            })]
        case "get_status": return status()
        case "respond_to_invite", "set_event_color", "join_meeting", "hide_from_panel", "snooze_alert":
            return try await action(name, a, client: client)
        default:
            throw MCPToolError("Unknown tool \(name).")
        }
    }

    private func detailed(_ m: Meeting) -> JSONValue {
        let inClash = state.clashes.contains { $0.meetings.contains { $0.id == m.id } }
        let dto = MeetingDTO(m, now: Date(), inClash: inClash, mutedByClash: state.suppressedByClash.contains(m.id),
                             hiddenFromPanel: state.isHiddenFromPanel(m), agendaOnly: state.isAgendaOnly(m),
                             includeNotes: true)
        return (try? JSONValue(encoding: dto)) ?? .null
    }

    /// Accepts "2026-11-18", full ISO 8601 date-times, "today" and "tomorrow".
    private func date(_ v: JSONValue?) throws -> Date? {
        guard let s = v?.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let cal = Calendar.current
        switch s.lowercased() {
        case "today": return cal.startOfDay(for: Date())
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
        default: break
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        throw MCPToolError("Couldn't read the date \"\(s)\". Use ISO 8601, e.g. 2026-11-18 or 2026-11-18T14:00.")
    }

    /// Cadence fetches today and tomorrow; say so when asked about more.
    private var loadedUntil: Date {
        Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))!
    }

    private func agenda(_ a: [String: JSONValue]) throws -> JSONValue {
        let cal = Calendar.current
        let from: Date, to: Date
        if let day = try date(a["date"]) {
            from = cal.startOfDay(for: day)
            to = cal.date(byAdding: .day, value: 1, to: from)!
        } else {
            from = try date(a["from"]) ?? cal.startOfDay(for: Date())
            to = try date(a["to"]) ?? cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: from))!
        }
        let includeDeclined = a["include_declined"]?.boolValue ?? false
        let list = state.meetings.filter { $0.end > from && $0.start < to && (includeDeclined || $0.participation != .declined) }
        var out: [String: JSONValue] = [
            "from": .string(MeetingDTO.format(from)), "to": .string(MeetingDTO.format(to)),
            "meetings": .array(list.map(state.dto)),
        ]
        if to > loadedUntil || from < cal.startOfDay(for: Date()) {
            out["note"] = "Cadence only loads today and tomorrow, so meetings outside that window are missing."
        }
        return .object(out)
    }

    private func clashes() -> JSONValue {
        ["clashes": .array(state.clashes.map { clash in
            let choice = state.clashChoices[clash.key]
            return ["meetings": .array(clash.meetings.map(state.dto)),
                    "alerting_for": choice.map { $0 == "all" ? "all" : JSONValue.string($0) } ?? "undecided"]
        })]
    }

    private func freeTime(_ a: [String: JSONValue]) throws -> JSONValue {
        guard let minutes = a["duration_minutes"]?.intValue, minutes >= 5 else {
            throw MCPToolError("duration_minutes must be at least 5.")
        }
        var hours = (state.prefs.workStart, state.prefs.workEnd)
        if let custom = a["working_hours"]?.stringValue {
            guard let parsed = FreeTimeFinder.parseHours(custom) else { throw MCPToolError("working_hours should look like 09:00-17:30.") }
            hours = parsed
        }
        let from = max(Date(), try date(a["from"]) ?? Date())
        let to = min(loadedUntil, try date(a["to"]) ?? loadedUntil)
        let slots = FreeTimeFinder.slots(meetings: state.activeMeetings, from: from, to: to, minDuration: Double(minutes) * 60,
                                         workStart: hours.0, workEnd: hours.1)
        return [
            "slots": .array(slots.map {
                ["start": .string(MeetingDTO.format($0.start)), "end": .string(MeetingDTO.format($0.end)),
                 "minutes": .number(($0.duration / 60).rounded())]
            }),
            "working_hours": .string(String(format: "%02d:%02d-%02d:%02d", hours.0 / 60, hours.0 % 60, hours.1 / 60, hours.1 % 60)),
            "note": "Based on the meetings Cadence loads (today and tomorrow), skipping weekends, free and declined events, and agenda-only calendars.",
        ]
    }

    private func status() -> JSONValue {
        let ctx = SystemContext.current()
        var out: [String: JSONValue] = [
            "presenting": .bool(ctx.isPresenting),
            "on_call": .bool(ctx.microphoneApp != nil),
            "call_app": ctx.microphoneApp.map { .string($0) } ?? .null,
            "now": .string(MeetingDTO.format(Date())),
        ]
        if let next = state.next {
            out["next_meeting"] = state.dto(next)
            if state.prefs.takeoverEnabled {
                out["next_alert"] = .string(MeetingDTO.format(next.start.addingTimeInterval(-state.prefs.takeoverLeadSeconds)))
            }
        }
        if !state.current.isEmpty { out["in_meeting"] = .array(state.current.map(state.dto)) }
        return .object(out)
    }

    // MARK: Actions

    private func meeting(_ a: [String: JSONValue]) throws -> Meeting {
        guard let id = a["meeting_id"]?.stringValue else { throw MCPToolError("meeting_id is required.") }
        let all = state.meetings + state.invites + state.allMeetings
        guard let m = all.first(where: { $0.id == id }) else {
            throw MCPToolError("No meeting with id \(id). Get ids from get_agenda, get_next_meeting or list_invites.")
        }
        return m
    }

    private func action(_ name: String, _ a: [String: JSONValue], client: String) async throws -> JSONValue {
        let m = try meeting(a)
        let summary: String
        var perform: () async throws -> Void

        switch name {
        case "respond_to_invite":
            guard let reply = a["reply"]?.stringValue.flatMap(RSVP.init(rawValue:)) else {
                throw MCPToolError("reply must be accept, tentative or decline.")
            }
            summary = "\(reply.label) the invite"
            perform = { try await self.state.respond(m, reply) }
        case "set_event_color":
            let raw = a["color"]?.stringValue
            // The calendar's own label names win; Google's standard names still work.
            let choices = state.colorChoices(for: m)
            let choice = raw.flatMap { name in
                choices.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    ?? choices.first { EventColorChoice.choice(id: $0.id)?.name.caseInsensitiveCompare(name) == .orderedSame }
            }
            if raw != nil && choice == nil {
                throw MCPToolError("Unknown colour. Use one of: " + choices.map(\.detail).joined(separator: ", ") + ", or null.")
            }
            summary = choice.map { "Colour it \($0.name)" } ?? "Reset it to the calendar colour"
            perform = { try await self.state.setColor(m, choice) }
        case "join_meeting":
            guard let link = m.joinLink else { throw MCPToolError("\(m.title) has no meeting link.") }
            summary = "Open \(link.service.displayName)"
            perform = { self.state.join(m) }
        case "hide_from_panel":
            let all = a["all_occurrences"]?.boolValue ?? false
            summary = all && m.recurs ? "Hide every occurrence from the countdown panel" : "Hide it from the countdown panel"
            perform = { self.state.hideFromPanel(m, series: all && m.recurs) }
        default:  // snooze_alert
            let minutes = min(30, max(1, a["minutes"]?.intValue ?? 1))
            summary = "Snooze its alert for \(minutes) min"
            perform = { self.state.snooze(m, seconds: Double(minutes) * 60) }
        }

        let auto = state.prefs.mcpAutoApprove.contains(name)
        if !auto {
            let note = "\(summary) · \(m.title)"
            switch await approvals.request(ApprovalRequest(client: client, tool: name, summary: summary, meeting: m)) {
            case .allowed: break
            case .denied:
                throw MCPToolError("The user declined this in Cadence (\(summary.lowercased()) for \(m.title)).", kind: .denied, note: note)
            case .timedOut:
                throw MCPToolError("The user didn't answer in Cadence within a minute, so nothing was changed.", kind: .timedOut, note: note)
            }
        }
        try await perform()
        return ["done": true, "action": .string(summary), "meeting": state.dto(m), "approved_by": auto ? "auto" : "user"]
    }

    // MARK: Resources

    func readResource(_ uri: String) async throws -> JSONValue {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch uri {
        case "cadence://agenda/today":
            return try agenda(["date": .string(MeetingDTO.format(today))])
        case "cadence://agenda/tomorrow":
            return try agenda(["date": .string(MeetingDTO.format(cal.date(byAdding: .day, value: 1, to: today)!))])
        case "cadence://next":
            if let live = state.current.last { return ["in_progress": detailed(live), "next": state.next.map(detailed) ?? .null] }
            return ["next": state.next.map(detailed) ?? .null]
        case "cadence://invites":
            return ["invites": .array(state.invites.map(state.dto))]
        case "cadence://clashes": return clashes()
        case "cadence://status": return status()
        default: throw MCPToolError("Unknown resource \(uri)")
        }
    }
}
