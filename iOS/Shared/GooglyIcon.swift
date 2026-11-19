import SwiftUI

/// The icon's three stages, matching the Mac's menu bar (`IconMood` in CadenceCore, which the widget
/// extension doesn't link).
enum ActivityMood: String, Codable, Hashable {
    case calm, nervous, panicking
}

/// The Mac's menu bar icon, drawn in SwiftUI for the Dynamic Island: a tiny calendar page with
/// mismatched googly eyes that gets more anxious as the next meeting gets close. Same geometry as
/// `MenuBarIcon` on the Mac (an 18-high canvas, y flipped), one colour, tinted by `foregroundStyle`.
struct GooglyIcon: View {
    var mood: ActivityMood
    /// Height in points; the icon is 20 × 18 at 1×.
    var height: CGFloat = 18

    var body: some View {
        ZStack(alignment: .topLeading) {
            GooglyPage.PageOutline().stroke(lineWidth: 1.4)
            GooglyPage.Lines(mood: mood).stroke(style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            GooglyPage.Fills(mood: mood).fill()
        }
        .frame(width: 20, height: 18)
        // Slight tilt once it's anxious, like the big icon running late.
        .rotationEffect(.radians(mood == .calm ? 0 : 0.08), anchor: UnitPoint(x: 9 / 20, y: 9.5 / 18))
        .scaleEffect(height / 18, anchor: .topLeading)
        .frame(width: 20 * height / 18, height: height, alignment: .topLeading)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch mood {
        case .calm: "Cadence"
        case .nervous: "Cadence, meeting soon"
        case .panicking: "Cadence, meeting in a few minutes"
        }
    }
}

private enum GooglyPage {
    static let page = CGRect(x: 1.5, y: 3.5, width: 14.5, height: 13.5)

    struct PageOutline: Shape {
        func path(in rect: CGRect) -> Path { Path(roundedRect: GooglyPage.page, cornerRadius: 3) }
    }

    /// Eye rings and the calm smile.
    struct Lines: Shape {
        var mood: ActivityMood
        func path(in rect: CGRect) -> Path {
            var p = Path()
            for eye in GooglyPage.eyes { p.addEllipse(in: eye.ring) }
            if mood == .calm {
                p.move(to: CGPoint(x: 7.4, y: 14.4))
                p.addCurve(to: CGPoint(x: 10.6, y: 14.4), control1: CGPoint(x: 8.2, y: 15.6), control2: CGPoint(x: 9.8, y: 15.6))
            }
            return p
        }
    }

    /// Header band, binder rings, pupils, the "o"/"O" mouth and the sweat drop.
    struct Fills: Shape {
        var mood: ActivityMood
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let page = Path(roundedRect: GooglyPage.page, cornerRadius: 3)
            let band = Path(CGRect(x: GooglyPage.page.minX, y: GooglyPage.page.minY, width: GooglyPage.page.width, height: 3.2))
            p.addPath(band.intersection(page))
            for x in [5.0, 12.5] {
                p.addRoundedRect(in: CGRect(x: x - 0.9, y: 1.3, width: 1.8, height: 3.4), cornerSize: CGSize(width: 0.9, height: 0.9))
            }
            for eye in GooglyPage.eyes { p.addEllipse(in: eye.pupil) }
            switch mood {
            case .calm: break
            case .nervous: p.addEllipse(in: CGRect(x: 8.1, y: 14.0, width: 1.9, height: 1.7))
            case .panicking: p.addEllipse(in: CGRect(x: 7.6, y: 13.5, width: 2.9, height: 2.6))
            }
            if mood == .panicking {
                p.move(to: CGPoint(x: 18.4, y: 2.4))
                p.addCurve(to: CGPoint(x: 18.4, y: 6.6), control1: CGPoint(x: 17.9, y: 3.8), control2: CGPoint(x: 16.8, y: 6.6))
                p.addCurve(to: CGPoint(x: 18.4, y: 2.4), control1: CGPoint(x: 20.0, y: 6.6), control2: CGPoint(x: 18.9, y: 3.8))
            }
            return p
        }
    }

    struct Eye {
        var center: CGPoint
        var r: CGFloat
        /// Which way the pupil looks (y down).
        var look: CGVector
        var ring: CGRect { CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2) }
        var pupil: CGRect {
            let pr = r * 0.48
            let c = CGPoint(x: center.x + look.dx * (r - pr - 0.5), y: center.y + look.dy * (r - pr - 0.5))
            return CGRect(x: c.x - pr, y: c.y - pr, width: pr * 2, height: pr * 2)
        }
    }

    static let eyes = [
        Eye(center: CGPoint(x: 6, y: 10.6), r: 2.7, look: CGVector(dx: 0.7, dy: -0.6)),
        Eye(center: CGPoint(x: 11.8, y: 10.8), r: 2.3, look: CGVector(dx: -0.6, dy: 0.7)),
    ]
}

/// The icon character off duty: the calendar page with drowsy, half-lidded googly eyes and a big
/// smile, holding a steaming cup of tea. For when the day's meetings are all done. Drawn on a 30 × 22
/// canvas (the page is the same as `GooglyIcon`'s); the page takes `foregroundStyle`, the cup `cup`.
/// When animated it glances about, now and then lets out a long contented sigh, and the steam curls.
struct GooglyTeaBreak: View {
    /// Height in points; the drawing is 30 × 22 at 1×.
    var height: CGFloat = 22
    var cup: Color = Color(red: 0.93, green: 0.62, blue: 0.38)
    var animated = true

    private static let size = CGSize(width: 30, height: 22)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { context in
            drawing(TeaBreak.Pose(time: animated ? context.date.timeIntervalSinceReferenceDate : nil))
        }
        .scaleEffect(height / Self.size.height, anchor: .topLeading)
        .frame(width: Self.size.width * height / Self.size.height, height: height, alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel("Cadence, relaxing with a cup of tea")
    }

    private func drawing(_ pose: TeaBreak.Pose) -> some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                GooglyPage.PageOutline().stroke(lineWidth: 1.4)
                TeaBreak.Face(sigh: pose.sigh).stroke(style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                TeaBreak.FaceFills(pose: pose).fill()
            }
            // The sigh: a slow breath in that lifts the page, then lets it settle.
            .scaleEffect(x: 1 + pose.breath * 0.025, y: 1 + pose.breath * 0.06, anchor: UnitPoint(x: 9 / 30, y: 17 / 22))
            TeaBreak.Arm().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            TeaBreak.Cup().fill(cup)
            TeaBreak.Handle().stroke(cup, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            TeaBreak.Saucer().stroke(cup, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            ForEach(0..<2, id: \.self) { i in
                TeaBreak.Wisp(x: [20.6, 23.4][i], phase: pose.steam + Double(i) * 2.1)
                    .stroke(style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                    .opacity(0.35 + 0.25 * sin(pose.steam * 0.7 + Double(i) * 1.7))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Flatten the layers first, so any opacity from outside (a translucent style, a dimmed
        // screen) applies once to the whole drawing instead of darkening where strokes overlap.
        .compositingGroup()
        // A little lean back, like it's put its feet up.
        .rotationEffect(.radians(-0.05), anchor: UnitPoint(x: 9 / 30, y: 17 / 22))
    }
}

private enum TeaBreak {
    /// Everything that moves, worked out from the clock (nil: the still drawing).
    struct Pose {
        /// 0…1: how far into a sigh (lids droop, pupils settle, smile widens).
        var sigh: CGFloat = 0
        /// 0…1: the breath in and out that goes with it.
        var breath: CGFloat = 0
        /// Where both eyes are looking, added to each eye's own (mismatched) gaze.
        var glance = CGVector.zero
        var steam: Double = 0

        init(time: TimeInterval?) {
            guard let t = time else { return }
            steam = t * 1.6
            // A sigh every 9 s, 3 s long: breathe in for the first 40%, then out slowly.
            let cycle = 9.0, length = 3.0
            let into = t.truncatingRemainder(dividingBy: cycle)
            if into < length {
                let u = into / length
                let rise = u < 0.4 ? u / 0.4 : 1 - (u - 0.4) / 0.6
                breath = CGFloat(Self.ease(rise))
                // Eyes close in contentment through the middle of it.
                sigh = CGFloat(Self.ease(min(1, sin(u * .pi) * 1.6)))
            }
            // Between sighs, glance somewhere new every 2.2 s, moving over a quarter second.
            let looks: [CGVector] = [.zero, CGVector(dx: -0.9, dy: -0.15), CGVector(dx: -0.5, dy: 0.1),
                                     CGVector(dx: 0.25, dy: -0.35), .zero, CGVector(dx: -1.1, dy: -0.3)]
            let step = 2.2
            let n = Int(t / step)
            let from = looks[(n + looks.count - 1) % looks.count], to = looks[n % looks.count]
            let k = CGFloat(Self.ease(min(1, (t - Double(n) * step) / 0.25)))
            glance = CGVector(dx: from.dx + (to.dx - from.dx) * k, dy: from.dy + (to.dy - from.dy) * k)
        }

        private static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    }

    /// Same rings as the icon, glancing at the tea by default.
    static let eyes = [
        GooglyPage.Eye(center: CGPoint(x: 6, y: 10.6), r: 2.7, look: CGVector(dx: 0.45, dy: 0.85)),
        GooglyPage.Eye(center: CGPoint(x: 11.8, y: 10.8), r: 2.3, look: CGVector(dx: 0.6, dy: 0.75)),
    ]

    /// Where the lid's lower edge meets the ring: half down, lower during a sigh. It sags a little
    /// in the middle.
    static func lidY(_ eye: GooglyPage.Eye, sigh: CGFloat) -> CGFloat { eye.center.y - eye.r * (0.35 - 0.25 * sigh) }

    /// A smaller pupil than the icon's, kept low in the eye, so a dark gap keeps it apart from the
    /// lid (everything is one solid colour, so touching shapes would merge). In a sigh it drops
    /// to the bottom and shrinks, staying clear of the lowered lid.
    static func pupil(_ eye: GooglyPage.Eye, pose: Pose) -> CGRect {
        let pr = eye.r * (0.4 - 0.08 * pose.sigh)
        let reach = eye.r - pr - 0.45
        var look = CGVector(dx: eye.look.dx + pose.glance.dx, dy: eye.look.dy + pose.glance.dy)
        // Never up under the lid; settle straight down while sighing.
        look.dy = max(look.dy, 0.45)
        look = CGVector(dx: look.dx * (1 - pose.sigh), dy: look.dy + (1 - look.dy) * pose.sigh)
        let len = max(1, (look.dx * look.dx + look.dy * look.dy).squareRoot())
        let c = CGPoint(x: eye.center.x + look.dx / len * reach, y: eye.center.y + look.dy / len * reach)
        return CGRect(x: c.x - pr, y: c.y - pr, width: pr * 2, height: pr * 2)
    }

    /// Eye rings and a wide, easy smile (wider mid-sigh).
    struct Face: Shape {
        var sigh: CGFloat
        func path(in rect: CGRect) -> Path {
            var p = Path()
            for eye in TeaBreak.eyes { p.addEllipse(in: eye.ring) }
            let w = 0.3 * sigh, d = 0.5 * sigh
            p.move(to: CGPoint(x: 6.9 - w, y: 14.3))
            p.addCurve(to: CGPoint(x: 11.1 + w, y: 14.3), control1: CGPoint(x: 7.9 - w, y: 16.0 + d), control2: CGPoint(x: 10.1 + w, y: 16.0 + d))
            return p
        }
    }

    /// Header band, binder rings, the heavy lids and the pupils under them.
    struct FaceFills: Shape {
        var pose: Pose
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let page = Path(roundedRect: GooglyPage.page, cornerRadius: 3)
            let band = Path(CGRect(x: GooglyPage.page.minX, y: GooglyPage.page.minY, width: GooglyPage.page.width, height: 3.2))
            p.addPath(band.intersection(page))
            for x in [5.0, 12.5] {
                p.addRoundedRect(in: CGRect(x: x - 0.9, y: 1.3, width: 1.8, height: 3.4), cornerSize: CGSize(width: 0.9, height: 0.9))
            }
            for eye in TeaBreak.eyes {
                let ring = Path(ellipseIn: eye.ring)
                var lid = Path()
                let y = TeaBreak.lidY(eye, sigh: pose.sigh)
                lid.move(to: CGPoint(x: eye.center.x - eye.r - 1, y: eye.center.y - eye.r - 1))
                lid.addLine(to: CGPoint(x: eye.center.x + eye.r + 1, y: eye.center.y - eye.r - 1))
                lid.addLine(to: CGPoint(x: eye.center.x + eye.r + 1, y: y))
                lid.addLine(to: CGPoint(x: eye.center.x + eye.r, y: y))
                lid.addQuadCurve(to: CGPoint(x: eye.center.x - eye.r, y: y), control: CGPoint(x: eye.center.x, y: y + eye.r * 0.25))
                lid.addLine(to: CGPoint(x: eye.center.x - eye.r - 1, y: y))
                lid.closeSubpath()
                p.addPath(lid.intersection(ring))
                p.addEllipse(in: TeaBreak.pupil(eye, pose: pose))
            }
            return p
        }
    }

    /// An arm reaching from the page's side to the cup.
    struct Arm: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 16.0, y: 12.6))
            p.addQuadCurve(to: CGPoint(x: 18.6, y: 15.4), control: CGPoint(x: 16.4, y: 15.6))
            return p
        }
    }

    /// The cup: a rounded mug body, a touch wider at the rim.
    struct Cup: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 18.2, y: 12.2))
            p.addLine(to: CGPoint(x: 25.8, y: 12.2))
            p.addCurve(to: CGPoint(x: 23.4, y: 18.2), control1: CGPoint(x: 25.8, y: 15.6), control2: CGPoint(x: 25.0, y: 18.2))
            p.addLine(to: CGPoint(x: 20.6, y: 18.2))
            p.addCurve(to: CGPoint(x: 18.2, y: 12.2), control1: CGPoint(x: 19.0, y: 18.2), control2: CGPoint(x: 18.2, y: 15.6))
            p.closeSubpath()
            return p
        }
    }

    struct Handle: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 25.6, y: 13.4))
            p.addCurve(to: CGPoint(x: 25.0, y: 16.6), control1: CGPoint(x: 28.4, y: 13.0), control2: CGPoint(x: 28.0, y: 16.6))
            return p
        }
    }

    struct Saucer: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 16.8, y: 19.2))
            p.addQuadCurve(to: CGPoint(x: 27.2, y: 19.2), control: CGPoint(x: 22.0, y: 20.4))
            return p
        }
    }

    /// One wisp of steam rising from the cup: a wave travelling up it, swaying more towards the
    /// top, the tip drifting as it goes.
    struct Wisp: Shape {
        var x: CGFloat
        var phase: Double
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let bottom: CGFloat = 10.8, top: CGFloat = 3.4 - 0.6 * CGFloat(sin(phase * 0.5))
            let steps = 16
            for i in 0...steps {
                let f = CGFloat(i) / CGFloat(steps)
                let y = bottom + (top - bottom) * f
                let sway = (0.35 + 0.9 * f) * CGFloat(sin(Double(f) * 5.5 - phase))
                let pt = CGPoint(x: x + sway, y: y)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }
    }
}
