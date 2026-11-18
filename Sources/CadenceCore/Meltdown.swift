import Foundation

/// The full-screen alert falling apart once panic has maxed out (3 minutes late and still ignored).
/// Letters ping off the heading and title and drop to the bottom of the screen; the countdown's
/// characters break off one by one and rattle around inside the ring like something in a shaken bottle.
/// Pure physics and timing, so it can be tested; the view only draws what's here.
public enum Meltdown {
    /// How late (seconds) before things start breaking.
    public static let startsAfter: TimeInterval = TakeoverUrgency.panicAfter
    /// Seconds over which it goes from the first crack to falling apart at full speed.
    public static let rampSeconds: TimeInterval = 120

    /// 0 before the meltdown starts, rising to 1 two minutes later.
    public static func progress(secondsLate: TimeInterval) -> Double {
        min(1, max(0, (secondsLate - startsAfter) / rampSeconds))
    }

    public static func isActive(secondsLate: TimeInterval) -> Bool { secondsLate >= startsAfter }

    /// Seconds until the next letter pings off: about every 4 s at first, every ~1.2 s at full meltdown.
    /// `jitter` is a random number in 0…1.
    public static func letterDelay(progress: Double, jitter: Double) -> TimeInterval {
        (4 - 2.8 * progress) * (0.6 + 0.8 * jitter)
    }

    /// Seconds until the next countdown character breaks off: ~7 s at first, ~3.5 s later.
    public static func digitDelay(progress: Double, jitter: Double) -> TimeInterval {
        (7 - 3.5 * progress) * (0.7 + 0.6 * jitter)
    }

    public static let gravity = 2200.0
}

public typealias Vec2 = SIMD2<Double>

/// A letter that has pinged off and is falling (in screen points, y down).
public struct FallingPiece: Equatable, Sendable {
    public var id: String
    public var position: Vec2
    public var velocity: Vec2
    public var angle: Double
    public var spin: Double
    public var resting = false

    public init(id: String, position: Vec2, velocity: Vec2, angle: Double = 0, spin: Double) {
        self.id = id
        self.position = position
        self.velocity = velocity
        self.angle = angle
        self.spin = spin
    }

    /// The random kick a letter gets as it breaks free: up and to one side, spinning.
    /// `r` is three random numbers in 0…1.
    public static func launch(id: String, from position: Vec2, r: (Double, Double, Double)) -> FallingPiece {
        FallingPiece(id: id, position: position,
                     velocity: Vec2((r.0 - 0.5) * 520, -(180 + r.1 * 380)),
                     spin: (r.2 - 0.5) * 14)
    }

    /// Advances by `dt` seconds. Bounces off the side walls, lands on `floor`, bounces a little, then rests.
    public mutating func step(dt: Double, floor: Double, width: Double, halfSize: Double = 14) {
        guard !resting, dt > 0 else { return }
        velocity.y += Meltdown.gravity * dt
        position += velocity * dt
        angle += spin * dt
        if position.x < halfSize { position.x = halfSize; velocity.x = abs(velocity.x) * 0.5 }
        if position.x > width - halfSize { position.x = width - halfSize; velocity.x = -abs(velocity.x) * 0.5 }
        if position.y >= floor - halfSize {
            position.y = floor - halfSize
            if abs(velocity.y) < 140 {
                resting = true
                velocity = .zero
                spin = 0
            } else {
                velocity.y = -velocity.y * 0.35
                velocity.x *= 0.6
                spin *= 0.5
            }
        }
    }
}

/// A countdown character loose inside the ring, relative to the ring's centre (y down).
public struct BottlePiece: Equatable, Sendable {
    /// Which character of the countdown it is, counted from the right (0 = last digit).
    public var slot: Int
    public var position: Vec2
    public var velocity: Vec2
    public var angle: Double
    public var spin: Double

    public init(slot: Int, position: Vec2, velocity: Vec2 = .zero, angle: Double = 0, spin: Double = 0) {
        self.slot = slot
        self.position = position
        self.velocity = velocity
        self.angle = angle
        self.spin = spin
    }

    /// Advances by `dt`. Gravity pulls it down, `shake` (points/s² — the bottle being shaken) throws it
    /// about, and the ring's inside wall (`radius` minus the piece's own size) bounces it back.
    public mutating func step(dt: Double, radius: Double, shake: Vec2, halfSize: Double = 26) {
        guard dt > 0 else { return }
        velocity += (Vec2(0, Meltdown.gravity * 0.45) + shake) * dt
        velocity *= max(0, 1 - 0.6 * dt) // a little air drag
        position += velocity * dt
        angle += spin * dt
        let limit = max(1, radius - halfSize)
        let distance = (position * position).sum().squareRoot()
        if distance > limit {
            let normal = position / distance
            position = normal * limit
            let into = (velocity * normal).sum()
            if into > 0 {
                velocity -= normal * into * 1.7 // bounce back with some loss
                // Scraping along the wall spins it.
                let tangent = Vec2(-normal.y, normal.x)
                spin = spin * 0.6 + (velocity * tangent).sum() / max(halfSize, 1) * 0.5
            }
        }
    }
}
