import SwiftUI

/// The googly calendar through the working day, to go with `GooglyTeaBreak` (no more meetings):
/// coffee before work, headphones on for focus time, lunch on a break, and a wave goodbye at the end
/// of the day. All drawn on the same 30 × 22 canvas as the tea break, the page in `foregroundStyle`
/// and the props in `prop`. Animated with the clock; still when `animated` is false (widgets).
enum MascotPose: String, Codable, Hashable, CaseIterable {
    case coffee, focus, lunch, tea, wave

    var accessibilityLabel: String {
        switch self {
        case .coffee: "Cadence, waking up with a coffee"
        case .focus: "Cadence, headphones on, focused"
        case .lunch: "Cadence, eating lunch"
        case .tea: "Cadence, relaxing with a cup of tea"
        case .wave: "Cadence, waving goodbye for the day"
        }
    }

    /// The prop's colour (cup, sandwich, laptop, moon).
    var propColor: Color {
        switch self {
        case .coffee: Color(red: 0.72, green: 0.50, blue: 0.36)
        case .focus: Color(red: 0.45, green: 0.72, blue: 1.0)
        case .lunch: Color(red: 0.96, green: 0.76, blue: 0.42)
        case .tea: Color(red: 0.93, green: 0.62, blue: 0.38)
        case .wave: Color(red: 1.0, green: 0.86, blue: 0.45)
        }
    }
}

/// Picks the drawing for a pose.
struct GooglyMascot: View {
    var pose: MascotPose
    var height: CGFloat = 22
    var animated = true
    /// Draw one moment of the animation (seconds into it), for previews and checks.
    var frozenAt: Double? = nil

    var body: some View {
        switch pose {
        case .tea: GooglyTeaBreak(height: height, cup: pose.propColor, animated: animated)
        default:
            MascotCanvas(height: height, animated: animated && frozenAt == nil, label: pose.accessibilityLabel) { live in
                let t = frozenAt ?? live
                switch pose {
                case .coffee: CoffeeDrawing(t: t, prop: pose.propColor)
                case .focus: FocusDrawing(t: t, prop: pose.propColor)
                case .lunch: LunchDrawing(t: t, prop: pose.propColor)
                default: WaveDrawing(t: t, prop: pose.propColor)
                }
            }
        }
    }
}

/// The 30 × 22 canvas, scaled to `height`, driven by the clock (nil time = still).
private struct MascotCanvas<Content: View>: View {
    var height: CGFloat
    var animated: Bool
    var label: String
    @ViewBuilder var content: (Double?) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { context in
            content(animated ? context.date.timeIntervalSinceReferenceDate : nil)
                .frame(width: 30, height: 22)
                // One layer, so outside opacity doesn't darken where strokes overlap.
                .compositingGroup()
        }
        .scaleEffect(height / 22, anchor: .topLeading)
        .frame(width: 30 * height / 22, height: height, alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

// MARK: - Shared parts

private enum Parts {
    static func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

    /// 0…1 while inside a window of `length` seconds that repeats every `cycle` seconds, rising and
    /// falling smoothly; 0 the rest of the time (and when still).
    static func pulse(_ t: Double?, cycle: Double, length: Double, offset: Double = 0) -> Double {
        guard let t else { return 0 }
        let into = (t + offset).truncatingRemainder(dividingBy: cycle)
        guard into < length else { return 0 }
        return sin(into / length * .pi)
    }

    /// A blink every few seconds: 0 open, 1 shut.
    static func blink(_ t: Double?, every: Double = 4.3) -> CGFloat {
        CGFloat(pulse(t, cycle: every, length: 0.18, offset: 1.3))
    }

    /// Page outline.
    struct Page: Shape {
        func path(in rect: CGRect) -> Path { Path(roundedRect: GooglyPage.page, cornerRadius: 3) }
    }

    /// Header band and binder rings.
    struct Chrome: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let page = Path(roundedRect: GooglyPage.page, cornerRadius: 3)
            let band = Path(CGRect(x: GooglyPage.page.minX, y: GooglyPage.page.minY, width: GooglyPage.page.width, height: 3.2))
            p.addPath(band.intersection(page))
            for x in [5.0, 12.5] {
                p.addRoundedRect(in: CGRect(x: x - 0.9, y: 1.3, width: 1.8, height: 3.4), cornerSize: CGSize(width: 0.9, height: 0.9))
            }
            return p
        }
    }

    /// The two eye rings (left open when `happy`: those are drawn as arcs instead).
    struct Rings: Shape {
        var happy = false
        /// Squeezed shut (a yawn): a downward curve per eye instead of the ring.
        var shut = false
        func path(in rect: CGRect) -> Path {
            var p = Path()
            for eye in GooglyPage.eyes {
                if shut {
                    p.move(to: CGPoint(x: eye.center.x - eye.r * 0.9, y: eye.center.y - eye.r * 0.1))
                    p.addQuadCurve(to: CGPoint(x: eye.center.x + eye.r * 0.9, y: eye.center.y - eye.r * 0.1),
                                   control: CGPoint(x: eye.center.x, y: eye.center.y + eye.r * 0.7))
                } else if happy {
                    // ^ ^ : closed, smiling eyes.
                    p.move(to: CGPoint(x: eye.center.x - eye.r * 0.85, y: eye.center.y + eye.r * 0.25))
                    p.addQuadCurve(to: CGPoint(x: eye.center.x + eye.r * 0.85, y: eye.center.y + eye.r * 0.25),
                                   control: CGPoint(x: eye.center.x, y: eye.center.y - eye.r * 0.9))
                } else {
                    p.addEllipse(in: eye.ring)
                }
            }
            return p
        }
    }

    /// Pupils looking along `look` (added to each eye's own mismatched gaze), under lids lowered by
    /// `lid` (0 open … 1 shut). Nothing when `happy`.
    struct Eyes: Shape {
        var look: CGVector
        var lid: CGFloat
        var pupil: CGFloat = 0.46
        var happy = false

        func path(in rect: CGRect) -> Path {
            var p = Path()
            guard !happy else { return p }
            // Never close all the way: a shut lid fills the ring into a blob. Use `Rings.shut` for that.
            let lid = min(lid, 0.6)
            for eye in GooglyPage.eyes {
                let ring = Path(ellipseIn: eye.ring)
                let lidY = eye.center.y - eye.r + 2 * eye.r * min(1, max(0, lid))
                if lid > 0.02 {
                    var l = Path()
                    l.move(to: CGPoint(x: eye.center.x - eye.r - 1, y: eye.center.y - eye.r - 1))
                    l.addLine(to: CGPoint(x: eye.center.x + eye.r + 1, y: eye.center.y - eye.r - 1))
                    l.addLine(to: CGPoint(x: eye.center.x + eye.r + 1, y: lidY))
                    l.addQuadCurve(to: CGPoint(x: eye.center.x - eye.r - 1, y: lidY),
                                   control: CGPoint(x: eye.center.x, y: lidY + eye.r * 0.25))
                    l.closeSubpath()
                    p.addPath(l.intersection(ring))
                }
                let pr = eye.r * pupil
                // Keep a clear dark gap between pupil and ring, so they read apart when small.
                let reach = max(0, eye.r - pr - 0.85)
                var v = CGVector(dx: eye.look.dx * 0.35 + look.dx, dy: eye.look.dy * 0.35 + look.dy)
                let len = max(1, (v.dx * v.dx + v.dy * v.dy).squareRoot())
                v = CGVector(dx: v.dx / len, dy: v.dy / len)
                var c = CGPoint(x: eye.center.x + v.dx * reach, y: eye.center.y + v.dy * reach)
                // Keep a dark gap under the lid (everything is one colour).
                if lid > 0.02 { c.y = max(c.y, min(eye.center.y + reach, lidY + pr + 0.5)) }
                p.addEllipse(in: CGRect(x: c.x - pr, y: c.y - pr, width: pr * 2, height: pr * 2))
            }
            return p
        }
    }

    /// A smile from `x0` to `x1`, `depth` deep.
    static func smile(_ x0: CGFloat, _ x1: CGFloat, y: CGFloat = 14.3, depth: CGFloat = 1.6) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y))
        p.addCurve(to: CGPoint(x: x1, y: y), control1: CGPoint(x: x0 + (x1 - x0) * 0.25, y: y + depth),
                   control2: CGPoint(x: x1 - (x1 - x0) * 0.25, y: y + depth))
        return p
    }

    /// The arm out to a prop held at the right.
    struct Arm: Shape {
        var to = CGPoint(x: 18.6, y: 15.4)
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 16.0, y: 12.6))
            p.addQuadCurve(to: to, control: CGPoint(x: 16.4, y: to.y + 0.2))
            return p
        }
    }

    struct Stroke: Shape {
        var path: Path
        func path(in rect: CGRect) -> Path { path }
    }
}

/// A page drawn in the foreground colour: outline, chrome, rings, eyes and a mouth.
private struct Face: View {
    var look: CGVector = .zero
    var lid: CGFloat = 0
    var happy = false
    var shut = false
    var mouthStroke: Path = Path()
    var mouthFill: Path = Path()
    var pupil: CGFloat = 0.46

    var body: some View {
        ZStack(alignment: .topLeading) {
            Parts.Page().stroke(lineWidth: 1.4)
            Parts.Chrome().fill()
            Parts.Rings(happy: happy, shut: shut).stroke(style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            Parts.Eyes(look: look, lid: lid, pupil: pupil, happy: happy || shut).fill()
            Parts.Stroke(path: mouthStroke).stroke(style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            Parts.Stroke(path: mouthFill).fill()
        }
        .frame(width: 30, height: 22, alignment: .topLeading)
    }
}

// MARK: - Before work: coffee and a yawn

private struct CoffeeDrawing: View {
    var t: Double?
    var prop: Color

    var body: some View {
        let yawn = CGFloat(Parts.ease(Parts.pulse(t, cycle: 7, length: 2.6) * 1.4))
        // Heavy-lidded, then squeezed shut through the big part of the yawn.
        let lid = 0.42 + 0.5 * Parts.blink(t, every: 5.1)
        let shut = yawn > 0.45
        var mouth = Path()
        if yawn > 0.05 {
            mouth.addEllipse(in: CGRect(x: 9.0 - 1.1 - 0.4 * yawn, y: 13.6, width: 2.2 + 0.8 * yawn, height: 0.8 + 2.4 * yawn))
        }
        let sleepy = yawn > 0.05 ? Path() : Parts.smile(7.8, 10.4, y: 14.6, depth: 0.5)
        let steam = (t ?? 0) * 1.6
        return ZStack(alignment: .topLeading) {
            Face(look: CGVector(dx: 0.5, dy: 0.8), lid: lid, shut: shut, mouthStroke: sleepy, mouthFill: mouth, pupil: 0.44)
                // The stretch of a big yawn.
                .scaleEffect(x: 1 - 0.02 * yawn, y: 1 + 0.06 * yawn, anchor: UnitPoint(x: 9 / 30, y: 17 / 22))
            Parts.Arm().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            // A mug: straighter than the teacup, no saucer.
            Parts.Stroke(path: Path(roundedRect: CGRect(x: 18.4, y: 11.6, width: 6.6, height: 7.0), cornerRadius: 1.4)).fill(prop)
            TeaBreak.Handle().stroke(prop, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                .offset(x: -0.6)
            ForEach(0..<2, id: \.self) { i in
                TeaBreak.Wisp(x: [20.4, 23.0][i], phase: steam + Double(i) * 2.1)
                    .stroke(style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                    .opacity(0.35 + 0.25 * sin(steam * 0.7 + Double(i) * 1.7))
            }
        }
    }
}

// MARK: - Focus: headphones on, eyes on the laptop

private struct FocusDrawing: View {
    var t: Double?
    var prop: Color

    var body: some View {
        let beat = t.map { CGFloat(sin($0 * 2 * .pi * 1.1)) } ?? 0
        let lid = 0.12 + 0.88 * Parts.blink(t)
        // Typing: three code lines growing and resetting at different speeds.
        let typed: [CGFloat] = (0..<3).map { i in
            guard let t else { return [0.8, 0.55, 0.7][i] }
            let speed = [0.9, 1.3, 0.7][i]
            return CGFloat(0.2 + 0.8 * ((t * speed + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)))
        }
        // Headphones held clear of the page: cups a gap outside its sides, the band arching well
        // above the binder rings, so nothing merges with the calendar's own shapes.
        var band = Path()
        band.move(to: CGPoint(x: -0.9, y: 7.6))
        band.addCurve(to: CGPoint(x: 18.4, y: 7.6), control1: CGPoint(x: -0.9, y: -4.6), control2: CGPoint(x: 18.4, y: -4.6))
        var cups = Path()
        cups.addRoundedRect(in: CGRect(x: -2.1, y: 7.4, width: 2.4, height: 5.6), cornerSize: CGSize(width: 1.1, height: 1.1))
        cups.addRoundedRect(in: CGRect(x: 17.2, y: 7.4, width: 2.4, height: 5.6), cornerSize: CGSize(width: 1.1, height: 1.1))
        var lines = Path()
        for (i, w) in typed.enumerated() {
            let y = 10.4 + CGFloat(i) * 1.6
            let x0: CGFloat = 22.2 + (i == 1 ? 0.9 : 0)
            lines.move(to: CGPoint(x: x0, y: y))
            lines.addLine(to: CGPoint(x: x0 + 4.6 * w, y: y))
        }
        var mouth = Path()
        mouth.move(to: CGPoint(x: 8.0, y: 14.7))
        mouth.addLine(to: CGPoint(x: 10.3, y: 14.4))
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Face(look: CGVector(dx: 0.9, dy: 0.25), lid: lid, mouthStroke: mouth)
                Parts.Stroke(path: band).stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                Parts.Stroke(path: cups).fill()
            }
            .offset(y: beat * 0.25)
            // Laptop: screen and base, with code being typed.
            Parts.Stroke(path: Path(roundedRect: CGRect(x: 21.0, y: 8.6, width: 7.8, height: 6.4), cornerRadius: 1.0))
                .stroke(prop, lineWidth: 1.1)
            Parts.Stroke(path: lines).stroke(prop, style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            Parts.Stroke(path: Path { p in p.move(to: CGPoint(x: 20.2, y: 16.2)); p.addLine(to: CGPoint(x: 29.6, y: 16.2)) })
                .stroke(prop, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
    }
}

// MARK: - On a break: lunch

private struct LunchDrawing: View {
    var t: Double?
    var prop: Color

    var body: some View {
        let chewing = Parts.pulse(t, cycle: 5, length: 2.4)
        let chew = t.map { CGFloat(0.5 + 0.5 * sin($0 * 2 * .pi * 2.6)) } ?? 0
        let happy = chewing > 0.2
        var mouthFill = Path()
        var mouthStroke = Path()
        if happy {
            mouthFill.addEllipse(in: CGRect(x: 8.0, y: 14.0, width: 2.4, height: 0.6 + 1.2 * chew))
        } else {
            mouthStroke = Parts.smile(7.0, 11.0, depth: 1.8)
        }
        // A triangle sandwich with a bite out of it, and a stripe of filling.
        let bread = Path { p in
            p.move(to: CGPoint(x: 18.0, y: 17.4))
            p.addLine(to: CGPoint(x: 27.2, y: 17.4))
            p.addLine(to: CGPoint(x: 22.6, y: 9.4))
            p.closeSubpath()
        }
        let bitten = bread.subtracting(Path(ellipseIn: CGRect(x: 21.2, y: 8.0, width: 2.8, height: 2.8)))
        let filling = Path { p in
            p.move(to: CGPoint(x: 19.6, y: 15.4)); p.addLine(to: CGPoint(x: 25.6, y: 15.4))
        }
        // Crumbs falling while it chews.
        let fall = t.map { CGFloat(($0 * 1.2).truncatingRemainder(dividingBy: 1)) } ?? 0
        let crumbs = Path { p in
            guard happy else { return }
            p.addEllipse(in: CGRect(x: 10.6, y: 16.0 + fall * 4, width: 0.7, height: 0.7))
            p.addEllipse(in: CGRect(x: 8.2, y: 16.8 + fall * 3, width: 0.6, height: 0.6))
        }
        return ZStack(alignment: .topLeading) {
            Face(look: CGVector(dx: 0.75, dy: 0.55), lid: 0.15 + 0.85 * Parts.blink(t), happy: happy,
                 mouthStroke: mouthStroke, mouthFill: mouthFill)
                .offset(y: happy ? -0.15 * chew : 0)
            Parts.Arm(to: CGPoint(x: 18.8, y: 15.0)).stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            Parts.Stroke(path: bitten).fill(prop)
            Parts.Stroke(path: filling).stroke(Color(red: 0.45, green: 0.8, blue: 0.4), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            Parts.Stroke(path: crumbs).fill(prop)
        }
    }
}

// MARK: - End of the day: a wave goodbye under the moon

private struct WaveDrawing: View {
    var t: Double?
    var prop: Color

    var body: some View {
        let waving = Parts.pulse(t, cycle: 5, length: 2.4)
        let swing = t.map { sin($0 * 2 * .pi * 2.2) } ?? 0
        let angle = -0.95 + 0.38 * swing * waving - (1 - waving) * 0.1
        let shoulder = CGPoint(x: 16.0, y: 11.0)
        let hand = CGPoint(x: shoulder.x + CGFloat(cos(angle)) * 6.4, y: shoulder.y + CGFloat(sin(angle)) * 6.4)
        let arm = Path { p in
            p.move(to: shoulder)
            p.addQuadCurve(to: hand, control: CGPoint(x: shoulder.x + 2.6, y: shoulder.y - 0.6))
        }
        let palm = Path(ellipseIn: CGRect(x: hand.x - 1.2, y: hand.y - 1.2, width: 2.4, height: 2.4))
        let moon = Path(ellipseIn: CGRect(x: 23.4, y: 1.4, width: 5.2, height: 5.2))
            .subtracting(Path(ellipseIn: CGRect(x: 25.0, y: 0.6, width: 5.0, height: 5.0)))
        let twinkle = t.map { 0.4 + 0.6 * abs(sin($0 * 1.7)) } ?? 0.8
        let stars = Path { p in
            for (x, y, r) in [(21.6, 3.0, 0.5), (28.0, 9.2, 0.45), (25.4, 12.6, 0.4)] as [(CGFloat, CGFloat, CGFloat)] {
                p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }
        return ZStack(alignment: .topLeading) {
            Face(look: CGVector(dx: 0.1, dy: 0.15), lid: 0.1 + 0.9 * Parts.blink(t), happy: waving > 0.3,
                 mouthStroke: Parts.smile(6.6, 11.4, y: 14.0, depth: 2.2))
            Parts.Stroke(path: arm).stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            Parts.Stroke(path: palm).fill()
            Parts.Stroke(path: moon).fill(prop)
            Parts.Stroke(path: stars).fill(prop).opacity(twinkle)
        }
    }
}
