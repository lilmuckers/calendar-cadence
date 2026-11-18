import Foundation

/// How worked up the full-screen takeover gets once a meeting has started and nobody has joined.
/// `level` runs from 0 (on time) to 1 (full panic, `panicAfter` seconds late).
public struct TakeoverUrgency: Equatable, Sendable {
    public static let panicAfter: TimeInterval = 180

    public var level: Double

    public init(secondsLate: TimeInterval) {
        level = min(1, max(0, secondsLate / Self.panicAfter))
    }

    public init(level: Double) { self.level = min(1, max(0, level)) }

    private func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * level }

    /// One full grow-and-shrink of the glow, in seconds: calm 2 s down to a frantic 0.35 s.
    public var period: Double { lerp(2.0, 0.35) }

    /// The glow's scale at the bottom and top of each pulse. It swings wider as panic sets in.
    public var scaleRange: ClosedRange<Double> { lerp(0.6, 0.8)...lerp(1.0, 1.18) }

    /// Glow strength.
    public var glowOpacity: Double { lerp(0.8, 1.0) }

    /// How strongly a red edge flash and red wash show (0 when on time).
    public var alarm: Double { level * level }

    /// How far the content shakes, in points. Only starts halfway to full panic.
    public var shake: Double { max(0, level - 0.5) * 2 * 7 }

    /// The meeting's colour pulled toward an angry red.
    public func color(from base: RGBAColor) -> RGBAColor {
        RGBAColor(red: lerp(base.red, 1.0), green: lerp(base.green, 0.12), blue: lerp(base.blue, 0.1), alpha: 1)
    }

    /// The small caps line above the clock.
    public static func headline(remaining: TimeInterval) -> String {
        if remaining > 0 { return "STARTING IN" }
        let late = -remaining
        switch late {
        case ..<30: return "STARTED"
        case ..<90: return "YOU'RE LATE"
        case ..<150: return "THEY'RE WAITING FOR YOU"
        default: return "SERIOUSLY. JOIN. NOW."
        }
    }
}
