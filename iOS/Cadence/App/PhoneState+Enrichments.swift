import CadenceCore
import Foundation

/// What assistants attached to meetings, mirrored from the Mac (which keeps the real copy).
extension PhoneState {
    /// The Mac's last copy, while paired; works from the saved snapshot when out of reach.
    var enrichmentBook: EnrichmentBook {
        link.mac == nil ? EnrichmentBook() : snapshot?.enrichments ?? EnrichmentBook()
    }

    func enrichments(for m: Meeting) -> [Enrichment] { enrichmentBook.enrichments(for: m) }

    func enrichmentState(_ e: Enrichment, _ m: Meeting) -> EnrichmentState { enrichmentBook.state(e.id, meetingID: m.id) }

    /// Ticks and log entries go to the Mac, so they need the link.
    var canEditEnrichments: Bool { link.isConnected }

    /// The meeting the desk's Notes button is for: a live one with attachments (latest started),
    /// else the focused meeting if it has some.
    var deskEnrichmentMeeting: Meeting? {
        guard prefs.deskEnrichments else { return nil }
        if let live = current.filter({ !enrichments(for: $0).isEmpty }).max(by: { $0.start < $1.start }) { return live }
        if let f = focus?.meeting, !enrichments(for: f).isEmpty { return f }
        return nil
    }

    /// Applied here straight away, then sent to the Mac (whose next snapshot confirms it).
    func applyEnrichment(_ action: EnrichmentAction, meetingID: String) {
        guard link.isConnected else { return }
        updateSnapshotEnrichments { $0.apply(action, meetingID: meetingID) }
        link.send(.enrichmentAction(meetingID: meetingID, action: action))
    }
}
