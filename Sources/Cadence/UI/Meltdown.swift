import AppKit
import CadenceCore
import SwiftUI

/// Where each breakable character sits on screen, collected from the views that draw them.
struct GlyphAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

enum GlyphStyle {
    case heading, title, countdown

    func font(level: Double) -> Font {
        switch self {
        case .heading: .system(size: 15 + 5 * level, weight: .heavy)
        case .title: .system(size: 40, weight: .bold, design: .rounded)
        case .countdown: .system(size: 88, weight: .semibold, design: .rounded).monospacedDigit()
        }
    }
}

/// The meltdown's state for one takeover window. A plain reference type: the TimelineView redraws every
/// frame anyway, and `tick` runs once per frame from the overlay that can see every glyph's position.
final class MeltdownModel {
    private(set) var falling: [FallingPiece] = []
    private(set) var fallingGlyph: [String: (Character, GlyphStyle)] = [:]
    /// Letters (by id) that have broken off; their original spot shows only a faint shadow.
    private(set) var brokenLetters: Set<String> = []
    /// Countdown characters (by slot from the right) loose in the ring.
    private(set) var bottle: [BottlePiece] = []
    var brokenSlots: Set<Int> { Set(bottle.map(\.slot)) }

    private var lastTick: Date?
    private var nextLetter: Date?
    private var nextDigit: Date?

    /// `glyphs` maps each still-breakable character id to its frame (root coordinates) and character.
    func tick(date: Date, secondsLate: TimeInterval, glyphs: [String: (CGRect, Character, GlyphStyle)],
              ringCenter: CGPoint?, screen: CGSize, sound: Bool) {
        let dt = lastTick.map { min(1.0 / 20, max(0, date.timeIntervalSince($0))) } ?? 0
        lastTick = date
        guard Meltdown.isActive(secondsLate: secondsLate) else { return }
        let progress = Meltdown.progress(secondsLate: secondsLate)

        // Something new breaks off?
        if nextLetter == nil { nextLetter = date.addingTimeInterval(0.6) }
        if nextDigit == nil { nextDigit = date.addingTimeInterval(1.8) }

        if let due = nextLetter, date >= due {
            nextLetter = date.addingTimeInterval(Meltdown.letterDelay(progress: progress, jitter: .random(in: 0...1)))
            let candidates = glyphs.filter { id, g in
                g.2 != .countdown && !brokenLetters.contains(id) && !g.1.isWhitespace
            }
            if let (id, g) = candidates.randomElement(), falling.count < 160 {
                brokenLetters.insert(id)
                fallingGlyph[id] = (g.1, g.2)
                falling.append(.launch(id: id, from: Vec2(g.0.midX, g.0.midY),
                                       r: (.random(in: 0...1), .random(in: 0...1), .random(in: 0...1))))
                if sound { NSSound(named: "Pop")?.play() }
            }
        }

        if let due = nextDigit, date >= due, let ringCenter {
            nextDigit = date.addingTimeInterval(Meltdown.digitDelay(progress: progress, jitter: .random(in: 0...1)))
            let loose = brokenSlots
            let candidates = glyphs.compactMap { id, g -> (Int, CGRect)? in
                guard g.2 == .countdown, let slot = Int(id.dropFirst(2)), !loose.contains(slot) else { return nil }
                return (slot, g.0)
            }
            if let (slot, frame) = candidates.randomElement() {
                bottle.append(BottlePiece(slot: slot,
                                          position: Vec2(frame.midX - ringCenter.x, frame.midY - ringCenter.y),
                                          velocity: Vec2(.random(in: -300...300), .random(in: -500 ... -150)),
                                          spin: .random(in: -6...6)))
                if sound { NSSound(named: "Tink")?.play() }
            }
        }

        // Move everything.
        let floor = Double(screen.height) - 24
        for i in falling.indices {
            falling[i].step(dt: dt, floor: floor, width: Double(screen.width))
        }
        let violence = 7000 + 9000 * progress
        for i in bottle.indices {
            let kick = Vec2(.random(in: -1...1), .random(in: -1...1)) * violence
            bottle[i].step(dt: dt, radius: 124, shake: kick)
        }
    }
}

/// Text drawn one character at a time so single letters can break off. Words wrap as a unit and lines
/// are centred, like the plain Text it replaces during a meltdown.
struct BreakableText: View {
    let text: String
    let idPrefix: String
    let style: GlyphStyle
    let broken: Set<String>
    var tracking: CGFloat = 0
    var wordSpacing: CGFloat = 10

    var body: some View {
        let words = Self.words(text)
        CenteredFlow(spacing: wordSpacing, lineSpacing: 4) {
            ForEach(words, id: \.offset) { word in
                HStack(spacing: tracking) {
                    ForEach(word.chars, id: \.offset) { c in
                        let id = "\(idPrefix)-\(c.offset)"
                        Text(String(c.char))
                            .opacity(broken.contains(id) ? 0.13 : 1)
                            .blur(radius: broken.contains(id) ? 1.5 : 0)
                            .anchorPreference(key: GlyphAnchorKey.self, value: .bounds) { [id: $0] }
                    }
                }
            }
        }
    }

    struct Word { let offset: Int; let chars: [(offset: Int, char: Character)] }

    static func words(_ text: String) -> [Word] {
        var out: [Word] = []
        var current: [(Int, Character)] = []
        var start = 0
        for (i, ch) in text.enumerated() {
            if ch == " " {
                if !current.isEmpty { out.append(Word(offset: start, chars: current.map { ($0.0, $0.1) })) }
                current = []
                start = i + 1
            } else {
                current.append((i, ch))
            }
        }
        if !current.isEmpty { out.append(Word(offset: start, chars: current.map { ($0.0, $0.1) })) }
        return out
    }
}

/// The countdown drawn per character; slots count from the right so they stay put while it counts.
/// Broken-off slots leave a faint shadow; their live digit rattles around the ring instead.
struct BreakableCountdown: View {
    let text: String
    let broken: Set<Int>

    var body: some View {
        let chars = Array(text)
        HStack(spacing: 0) {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, ch in
                let slot = chars.count - 1 - i
                Text(String(ch))
                    .opacity(broken.contains(slot) ? 0.1 : 1)
                    .blur(radius: broken.contains(slot) ? 2 : 0)
                    .anchorPreference(key: GlyphAnchorKey.self, value: .bounds) { ["d-\(slot)": $0] }
            }
        }
    }

    /// The character currently at `slot` (counted from the right), or nil if the text is shorter.
    static func character(in text: String, slot: Int) -> Character? {
        let chars = Array(text)
        guard slot < chars.count else { return nil }
        return chars[chars.count - 1 - slot]
    }
}

/// Wraps subviews onto centred lines.
struct CenteredFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > width {
                rows.append([])
                x = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rows[rows.count - 1].append((i, size))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let widest = rows.map { r in r.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, r.count - 1)) }.max() ?? 0
        let height = rows.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let rowWidth = row.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1))
            let rowHeight = row.map(\.1.height).max() ?? 0
            var x = bounds.midX - rowWidth / 2
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}
