import AppKit
import CadenceCore
import Observation
import SwiftUI

/// Profile photos for signed-in accounts, cached in Application Support so they survive relaunches
/// and are only re-downloaded once a day.
@MainActor
@Observable
final class AvatarStore {
    static let shared = AvatarStore()

    private(set) var images: [String: NSImage] = [:]
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

    func image(for key: String) -> NSImage? {
        if let cached = images[key] { return cached }
        guard let image = NSImage(contentsOf: file(key)) else { return nil }
        images[key] = image
        return image
    }

    /// True when there's no cached photo, or it's more than a day old.
    func isStale(_ key: String) -> Bool {
        let date = (try? file(key).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return date.map { Date().timeIntervalSince($0) > 86_400 } ?? true
    }

    func save(_ data: Data, for key: String) {
        guard let image = NSImage(data: data) else { return }
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

/// The account's photo (or initial) in a circle, with a small badge for the account type
/// in the bottom-right corner.
struct AccountAvatar: View {
    let key: String
    let label: String
    let kind: CalendarKind
    var size: CGFloat = 30

    var body: some View {
        let image = AvatarStore.shared.image(for: key)
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.secondary.opacity(0.35).gradient)
                        Text(initial)
                            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.1)))

            badge
                .frame(width: size * 0.46, height: size * 0.46)
                .background(Circle().fill(kind == .google ? Color.white : Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: size * 0.05))
                .offset(x: size * 0.1, y: size * 0.1)
        }
        .frame(width: size + size * 0.1, height: size + size * 0.1, alignment: .topLeading)
        .help("\(label) · \(kind.label)")
    }

    @ViewBuilder private var badge: some View {
        if kind == .google {
            CalendarKindBadge(kind: kind, size: size * 0.46, circular: true)
        } else {
            CalendarKindBadge(kind: kind, size: size * 0.3)
        }
    }

    private var initial: String {
        String(label.first { $0.isLetter } ?? "?").uppercased()
    }
}
