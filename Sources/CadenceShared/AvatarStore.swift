#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif
import Foundation
import Observation

/// Profile photos for signed-in accounts, cached in Application Support so they survive relaunches
/// and are only re-downloaded once a day.
@MainActor
@Observable
final class AvatarStore {
    static let shared = AvatarStore()

    private(set) var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Cadence/Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func file(_ key: String) -> URL {
        dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_"))
    }

    func image(for key: String) -> PlatformImage? {
        if let cached = images[key] { return cached }
        guard let image = PlatformImage(contentsOfFile: file(key).path) else { return nil }
        images[key] = image
        return image
    }

    /// True when there's no cached photo, or it's more than a day old.
    func isStale(_ key: String) -> Bool {
        let date = (try? file(key).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return date.map { Date().timeIntervalSince($0) > 86_400 } ?? true
    }

    func save(_ data: Data, for key: String) {
        guard let image = PlatformImage(data: data) else { return }
        try? data.write(to: file(key), options: .atomic)
        images[key] = image
    }

    /// Downloads `url` (at most once a day) and stores it under `key`.
    func refresh(_ key: String, from url: URL?) {
        guard let url, isStale(key), !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            defer { inFlight.remove(key) }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            save(data, for: key)
        }
    }

    /// Fetches with a custom request (e.g. a Graph call with a bearer token).
    func refresh(_ key: String, fetch: @escaping () async -> Data?) {
        guard isStale(key), !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            defer { inFlight.remove(key) }
            if let data = await fetch() { save(data, for: key) }
        }
    }

    func remove(_ key: String) {
        images[key] = nil
        try? FileManager.default.removeItem(at: file(key))
    }
}
