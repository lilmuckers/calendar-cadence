import Foundation

/// One paired Mac's agenda as the phone holds it.
public struct MacAgenda: Equatable, Sendable {
    public var macID: String
    public var snapshot: CompanionSnapshot

    public init(macID: String, snapshot: CompanionSnapshot) {
        self.macID = macID
        self.snapshot = snapshot
    }
}

/// A phone paired with several Macs sees the same meeting from each Mac that has it (often with a
/// different id on each). This merges their agendas into one, and finds each Mac's copy again so
/// Join, Snooze, prompts and enrichments reach the right Mac with the id that Mac knows.
public struct MultiMacAgenda: Equatable, Sendable {
    /// Highest priority first.
    public var agendas: [MacAgenda]

    public init(agendas: [MacAgenda]) {
        self.agendas = agendas
    }

    /// Every Mac's meetings, duplicates merged, in time order.
    public var meetings: [Meeting] {
        let all = agendas.flatMap(\.snapshot.meetings)
        guard agendas.count > 1 else { return all }
        return MeetingDeduplicator.dedupe(all.sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) })
    }

    /// Each Mac's own copy of `meeting`, highest priority first (at most one per Mac).
    public func copies(of meeting: Meeting) -> [(macID: String, meeting: Meeting)] {
        agendas.compactMap { agenda in
            let own = agenda.snapshot.meetings.first { $0.id == meeting.id }
                ?? agenda.snapshot.meetings.first { MeetingDeduplicator.isSameMeeting($0, meeting) }
            return own.map { (agenda.macID, $0) }
        }
    }

    /// `id` as some Mac knows it, found on whichever Mac has it.
    public func meeting(id: String) -> Meeting? {
        for agenda in agendas { if let m = agenda.snapshot.meetings.first(where: { $0.id == id }) { return m } }
        return nil
    }

    /// Ids muted on any Mac (clash choices, agenda-only calendars), carried over to every copy of the
    /// meeting so the merged one is muted whichever Mac's id it kept.
    public var suppressedIDs: Set<String> { spread { $0.suppressedIDs } }

    public var agendaOnlyIDs: Set<String> { spread { $0.agendaOnlyIDs ?? [] } }

    private func spread(_ ids: (CompanionSnapshot) -> Set<String>) -> Set<String> {
        var out = Set<String>()
        for agenda in agendas {
            let muted = ids(agenda.snapshot)
            out.formUnion(muted)
            guard agendas.count > 1 else { continue }
            for m in agenda.snapshot.meetings where muted.contains(m.id) {
                for other in agendas where other.macID != agenda.macID {
                    for o in other.snapshot.meetings where MeetingDeduplicator.isSameMeeting(o, m) { out.insert(o.id) }
                }
            }
        }
        return out
    }
}

/// Which connected Mac a meeting opens on when the phone is linked to several.
public enum MacJoinRouting {
    /// - `sources`: Macs whose own agenda has the meeting.
    /// - `connected`: connected Macs, highest priority first.
    /// - `canTakeLinks`: connected Macs that can open a meeting they don't have (`joinMeeting`).
    /// - `preferPriorityMac`: the user's "open browser links on the first Mac" setting.
    ///
    /// The meeting opens on the highest-priority connected Mac that has it. With only one Mac having
    /// it, a link any browser can open may go to the highest-priority Mac instead, if the user asked
    /// for that. A meeting no connected Mac has opens on the priority Mac when its link allows,
    /// else nil (join on the phone).
    public static func target(sources: [String], connected: [String], canTakeLinks: Set<String>,
                              link: MeetingLink?, preferPriorityMac: Bool) -> String? {
        let having = connected.filter(sources.contains)
        let browserLink = link?.opensInAnyBrowser == true
        let priority = connected.first { canTakeLinks.contains($0) }
        switch having.count {
        case 0:
            return browserLink ? priority : nil
        case 1:
            if preferPriorityMac, browserLink, let priority, connected.first == priority { return priority }
            return having[0]
        default:
            return having[0]
        }
    }
}

public extension MeetingLink {
    /// An ordinary web link, so any Mac with a browser can open it (not an app-only scheme like
    /// `zoommtg:` or `msteams:`).
    var opensInAnyBrowser: Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}
