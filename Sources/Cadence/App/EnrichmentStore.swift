import CadenceCore
import Foundation
import Observation

/// What assistants attached to meetings, and what the user ticked, in
/// Application Support/Cadence/enrichments.json. The Mac is the source of truth; the phone mirrors it.
@MainActor
@Observable
final class EnrichmentStore {
    private(set) var book: EnrichmentBook

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(file: URL? = nil) {
        let url = file ?? {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = base.appendingPathComponent("Cadence", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("enrichments.json")
        }()
        self.file = url
        var loaded = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(EnrichmentBook.self, from: $0) } ?? EnrichmentBook()
        loaded.prune()
        book = loaded
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    func enrichments(for m: Meeting) -> [Enrichment] { book.enrichments(for: m) }
    func state(_ e: Enrichment, _ m: Meeting) -> EnrichmentState { book.state(e.id, meetingID: m.id) }

    /// Changes the book and saves it (debounced, so a burst of ticks writes once).
    func mutate<T>(_ body: (inout EnrichmentBook) throws -> T) rethrows -> T {
        var copy = book
        let out = try body(&copy)
        if copy != book {
            book = copy
            scheduleSave()
        }
        return out
    }

    func prune() { mutate { $0.prune() } }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let data = try? Self.encoder.encode(book) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
