import CadenceCore
import Foundation

/// What assistants attached to meetings, mirrored from the Macs (each keeps the real copy of its own).
/// With several Macs, a meeting's attachments come from every Mac that has it, each found through
/// that Mac's own copy of the meeting.
extension PhoneState {
    /// Each Mac's copy of `m` with that Mac's enrichments, highest priority first.
    private func enrichmentSources(_ m: Meeting) -> [(macID: String, meeting: Meeting, book: EnrichmentBook)] {
        agenda.copies(of: m).compactMap { copy in
            snapshots[copy.macID]?.enrichments.map { (copy.macID, copy.meeting, $0) }
        }
    }

    func enrichments(for m: Meeting) -> [Enrichment] {
        var seen = Set<String>()
        return enrichmentSources(m).flatMap { $0.book.enrichments(for: $0.meeting) }.filter { seen.insert($0.id).inserted }
    }

    func enrichmentState(_ e: Enrichment, _ m: Meeting) -> EnrichmentState {
        guard let source = enrichmentSources(m).first(where: { $0.book.enrichment(id: e.id) != nil }) else {
            return EnrichmentState(enrichmentID: e.id, meetingID: m.id, updated: .distantPast)
        }
        return source.book.state(e.id, meetingID: source.meeting.id)
    }

    /// Ticks and log entries go to the Mac, so they need the link to the Mac that owns the enrichment.
    var canEditEnrichments: Bool { link.isConnected }

    /// The meeting the desk's Notes button is for: a live one with attachments (latest started),
    /// else the focused meeting if it has some.
    var deskEnrichmentMeeting: Meeting? {
        guard prefs.deskEnrichments else { return nil }
        if let live = current.filter({ !enrichments(for: $0).isEmpty }).max(by: { $0.start < $1.start }) { return live }
        if let f = focus?.meeting, !enrichments(for: f).isEmpty { return f }
        return nil
    }

    /// Applied here straight away, then sent to the Mac that owns the enrichment (whose next snapshot
    /// confirms it), in that Mac's meeting id.
    func applyEnrichment(_ action: EnrichmentAction, meetingID: String) {
        guard link.isConnected, let m = meeting(id: meetingID),
              let source = enrichmentSources(m).first(where: { $0.book.enrichment(id: action.enrichmentID) != nil }),
              link.link(source.macID)?.isConnected == true else { return }
        updateSnapshotEnrichments(macID: source.macID) { $0.apply(action, meetingID: source.meeting.id) }
        link.send(.enrichmentAction(meetingID: source.meeting.id, action: action), to: source.macID)
    }
}
