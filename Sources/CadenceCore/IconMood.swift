import Foundation

/// How anxious the googly-eyed calendar looks: the Mac's menu bar icon and the iPhone's Dynamic Island.
public enum IconMood: String, Codable, CaseIterable, Sendable {
    case calm, nervous, panicking

    /// Within this long of the next meeting it gets nervous, then panics.
    public static let nervousLead: TimeInterval = 15 * 60
    public static let panicLead: TimeInterval = 5 * 60

    /// The mood for an upcoming meeting starting at `start` (nil = nothing coming up).
    public static func forNext(start: Date?, now: Date) -> IconMood {
        guard let start else { return .calm }
        let remaining = start.timeIntervalSince(now)
        if remaining <= panicLead { return .panicking }
        if remaining <= nervousLead { return .nervous }
        return .calm
    }
}
