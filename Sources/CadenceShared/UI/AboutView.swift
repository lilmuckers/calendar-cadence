import SwiftUI

/// The About screen, shared by the Mac's About window and the iPhone's Settings: the app icon's
/// character drawn live on its sunburst. Its googly pupils follow the pointer (or a finger) and wobble
/// on springs; poke it and it gets more anxious, from "on time" to "LATE!".
struct AboutView: View {
    /// Where this copy runs, for the one feature tile that differs.
    var companionLine: (symbol: String, title: String) = {
        #if os(macOS)
        ("iphone", "iPhone companion on your desk")
        #else
        ("macbook", "Paired with Cadence on your Mac")
        #endif
    }()
    /// Set where this copy can show release notes: clicking the version shows what changed in it.
    var showVersionNotes: (() -> Void)?

    @State private var mood: AboutMascot.Mood = .calm
    @State private var target: CGPoint = .zero
    @State private var pokes = 0
    @State private var physics = GooglyPhysics()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            hero
            details
        }
    }

    // MARK: Hero

    private var hero: some View {
        GeometryReader { geo in
            let size = geo.size
            let side = min(size.width, size.height) * 0.72
            let center = CGPoint(x: size.width / 2, y: size.height * 0.52)
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let _ = physics.step(toward: target, at: timeline.date, jitter: mood == .panicking && !reduceMotion ? 1 : 0)
                Canvas { ctx, canvasSize in
                    AboutMascot.drawSunburst(in: &ctx, size: canvasSize, center: center, time: reduceMotion ? 0 : t, mood: mood)
                    AboutMascot.draw(in: &ctx, center: center, side: side, time: t, mood: mood,
                                     pupils: physics.positions, still: reduceMotion)
                }
            }
            .contentShape(Rectangle())
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): target = Self.look(from: p, center: center, side: side)
                case .ended: target = .zero
                }
            }
            #endif
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { target = Self.look(from: $0.location, center: center, side: side) }
                .onEnded { value in
                    #if !os(macOS)
                    target = .zero
                    #endif
                    if hypot(value.translation.width, value.translation.height) < 8 { poke() }
                })
            .overlay(alignment: .bottom) { caption.padding(.bottom, 14) }
        }
        .frame(height: 300)
        .clipped()
        .sensoryFeedback(.impact(weight: mood == .panicking ? .heavy : .light), trigger: pokes)
        .accessibilityElement()
        .accessibilityLabel("Cadence's calendar character, \(mood.accessibilityText)")
        .accessibilityHint("Poke to make it more anxious")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { poke() }
    }

    private var caption: some View {
        Text(pokes == 0 ? "Go on, poke it." : mood.caption)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.22), in: Capsule())
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: mood)
            .id(pokes == 0)
    }

    /// Pointer position as a look direction, about -1…1 across the character.
    private static func look(from p: CGPoint, center: CGPoint, side: CGFloat) -> CGPoint {
        CGPoint(x: (p.x - center.x) / (side * 0.6), y: (p.y - center.y) / (side * 0.6))
    }

    private func poke() {
        pokes += 1
        mood = mood.next
        physics.kick(strength: mood == .panicking ? 7 : 4)
    }

    // MARK: Details

    private var details: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Cadence")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [AboutMascot.pink, AboutMascot.orange],
                                                    startPoint: .leading, endPoint: .trailing))
                Text("Your calendar, gently panicking on your behalf.")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                versionBadge
                    .padding(.top, 4)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                FeatureTile(symbol: "calendar.badge.clock", title: "Every calendar, merged and de-duplicated", tint: AboutMascot.pink)
                FeatureTile(symbol: "video.fill", title: "Finds the join link wherever it hides", tint: AboutMascot.orange)
                FeatureTile(symbol: "rectangle.inset.filled", title: "Takes over the screen before you're due", tint: AboutMascot.red)
                FeatureTile(symbol: companionLine.symbol, title: companionLine.title, tint: AboutMascot.sky)
            }

            HStack(spacing: 8) {
                AboutLink(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", url: Self.repo)
                AboutLink(title: "Releases", symbol: "sparkles", url: Self.repo.appending(path: "releases"))
                AboutLink(title: "Feedback", symbol: "ladybug", url: Self.repo.appending(path: "issues/new/choose"))
            }

            Text("Made with SwiftUI, zero dependencies and a mild sense of panic.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 22)
    }

    @ViewBuilder private var versionBadge: some View {
        if let showVersionNotes {
            Button(action: showVersionNotes) {
                VersionBadge(tappable: true)
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .help("What's new in this version")
            #endif
            .accessibilityHint("Shows what changed in this version")
        } else {
            VersionBadge(tappable: false)
                .textSelection(.enabled)
        }
    }

    static let repo = URL(string: "https://github.com/lilmuckers/calendar-cadence")!

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }
}

/// "Version 1.2.3 (45)" in a capsule; with a sparkle and a hover highlight when it opens the notes.
private struct VersionBadge: View {
    let tappable: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(AboutView.version)
            if tappable { Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)) }
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(tappable && hovering ? AnyShapeStyle(AboutMascot.orange.opacity(0.18)) : AnyShapeStyle(.primary.opacity(0.06)),
                    in: Capsule())
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }
}

private struct FeatureTile: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AboutLink: View {
    let title: String
    let symbol: String
    let url: URL
    @State private var hovering = false

    var body: some View {
        Link(destination: url) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(AboutMascot.orange.opacity(hovering ? 0.22 : 0.12)))
                .foregroundStyle(AboutMascot.ink.opacity(0.9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        #if os(macOS)
        .help(url.absoluteString)
        #endif
    }
}

/// Spring-mounted pupils: each chases where it's told to look, overshoots and jiggles, and the two
/// are tuned differently so they never quite agree, like real googly eyes. A plain reference type,
/// stepped once per frame from the TimelineView.
final class GooglyPhysics {
    private struct Pupil {
        var p = CGPoint.zero
        var v = CGVector.zero
        let stiffness: CGFloat
        let damping: CGFloat
    }

    private var pupils = [Pupil(stiffness: 110, damping: 7), Pupil(stiffness: 70, damping: 4.5)]
    private var last: Date?

    var positions: [CGPoint] { pupils.map(\.p) }

    func step(toward target: CGPoint, at date: Date, jitter: CGFloat) {
        let dt = CGFloat(min(max(date.timeIntervalSince(last ?? date), 0), 1.0 / 30))
        last = date
        guard dt > 0 else { return }
        let len = hypot(target.x, target.y)
        let goal = len > 1 ? CGPoint(x: target.x / len, y: target.y / len) : target
        for i in pupils.indices {
            var pupil = pupils[i]
            let ax = (goal.x - pupil.p.x) * pupil.stiffness - pupil.v.dx * pupil.damping + .random(in: -1...1) * jitter * 60
            let ay = (goal.y - pupil.p.y) * pupil.stiffness - pupil.v.dy * pupil.damping + .random(in: -1...1) * jitter * 60 + 4
            pupil.v.dx += ax * dt
            pupil.v.dy += ay * dt
            pupil.p.x += pupil.v.dx * dt
            pupil.p.y += pupil.v.dy * dt
            // Bounce off the rim of the eye.
            let r = hypot(pupil.p.x, pupil.p.y)
            if r > 1 {
                let n = CGVector(dx: pupil.p.x / r, dy: pupil.p.y / r)
                pupil.p = CGPoint(x: n.dx, y: n.dy)
                let along = pupil.v.dx * n.dx + pupil.v.dy * n.dy
                if along > 0 {
                    pupil.v.dx -= 1.6 * along * n.dx
                    pupil.v.dy -= 1.6 * along * n.dy
                }
            }
            pupils[i] = pupil
        }
    }

    func kick(strength: CGFloat) {
        for i in pupils.indices {
            pupils[i].v.dx += .random(in: -1...1) * strength
            pupils[i].v.dy += .random(in: -1...1) * strength
        }
    }
}

/// The app icon's character, drawn on a 100 × 100 unit grid, and its sunburst.
enum AboutMascot {
    enum Mood: CaseIterable {
        case calm, nervous, panicking

        var next: Mood { self == .calm ? .nervous : self == .nervous ? .panicking : .calm }

        var header: String {
            switch self {
            case .calm: "ON TIME"
            case .nervous: "SOON…"
            case .panicking: "LATE!"
            }
        }

        var caption: String {
            switch self {
            case .calm: "Ahh. Nothing for ages."
            case .nervous: "Is that… a meeting?"
            case .panicking: "LATE! LATE! LATE!"
            }
        }

        var accessibilityText: String {
            switch self {
            case .calm: "calm"
            case .nervous: "a little nervous"
            case .panicking: "panicking"
            }
        }
    }

    static let pink = Color(red: 1.0, green: 0.42, blue: 0.54)
    static let orange = Color(red: 1.0, green: 0.60, blue: 0.30)
    static let yellow = Color(red: 1.0, green: 0.80, blue: 0.24)
    static let red = Color(red: 1.0, green: 0.23, blue: 0.28)
    static let ink = Color(red: 0.12, green: 0.11, blue: 0.17)
    static let sky = Color(red: 0.31, green: 0.74, blue: 0.97)
    private static let blush = Color(red: 1.0, green: 0.62, blue: 0.70)
    private static let tongue = Color(red: 1.0, green: 0.44, blue: 0.58)
    private static let throat = Color(red: 0.24, green: 0.04, blue: 0.11)
    private static let ring = Color(red: 0.25, green: 0.25, blue: 0.31)

    static func drawSunburst(in ctx: inout GraphicsContext, size: CGSize, center: CGPoint, time: TimeInterval, mood: Mood) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [pink, orange, yellow]),
                                                   startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        let speed: Double = mood == .panicking ? 0.5 : mood == .nervous ? 0.15 : 0.05
        let rays = 18
        let reach = hypot(size.width, size.height)
        var burst = Path()
        for i in 0..<rays {
            let a0 = Double(i) / Double(rays) * 2 * .pi + time * speed
            let a1 = a0 + .pi / Double(rays)
            burst.move(to: center)
            burst.addLine(to: CGPoint(x: center.x + cos(a0) * reach, y: center.y + sin(a0) * reach))
            burst.addLine(to: CGPoint(x: center.x + cos(a1) * reach, y: center.y + sin(a1) * reach))
            burst.closeSubpath()
        }
        ctx.fill(burst, with: .color(.white.opacity(0.09)))
        ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [.white.opacity(0.25), .clear]),
                                                    center: center, startRadius: 0, endRadius: reach * 0.4))
    }

    static func draw(in ctx: inout GraphicsContext, center: CGPoint, side: CGFloat, time t: TimeInterval,
                     mood: Mood, pupils: [CGPoint], still: Bool) {
        var c = ctx
        c.translateBy(x: center.x, y: center.y)
        // Gentle bob when calm, a fidget when nervous, a full-body tremble when panicking.
        let bob = still ? 0 : sin(t * 2.2) * 1.2
        let shake = still || mood != .panicking ? 0 : sin(t * 47) * 1.1
        let tilt = (mood == .calm ? -2.0 : -5.0) + (still ? 0 : mood == .nervous ? sin(t * 5) * 1.5 : shake)
        c.translateBy(x: shake * side / 100, y: bob * side / 100)
        c.rotate(by: .degrees(tilt))
        c.scaleBy(x: side / 100, y: side / 100)
        c.translateBy(x: -50, y: -50)

        if mood == .panicking { drawSpeedLines(in: &c, time: t, still: still) }

        let page = CGRect(x: 8, y: 14, width: 84, height: 80)
        let pagePath = Path(roundedRect: page, cornerRadius: 11, style: .continuous)
        var shadow = c
        shadow.addFilter(.shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 4))
        shadow.fill(pagePath, with: .color(.white))

        // Red header with the mood written on it.
        var header = c
        header.clip(to: pagePath)
        header.fill(Path(CGRect(x: page.minX, y: page.minY, width: page.width, height: 23)), with: .color(red))
        // Below the binder rings, so they never sit on the lettering.
        header.draw(Text(mood.header).font(.system(size: 11.5, weight: .black, design: .rounded)).foregroundStyle(.white),
                    at: CGPoint(x: 50, y: page.minY + 14.5))

        // Binder rings.
        for x in [30.0, 70.0] {
            let r = CGRect(x: x - 3.6, y: 5, width: 7.2, height: 14)
            c.fill(Path(roundedRect: r, cornerRadius: 3.6), with: .color(ring))
            c.fill(Path(roundedRect: r.insetBy(dx: 2.2, dy: 2.2), cornerRadius: 1.4), with: .color(.white.opacity(0.28)))
        }

        // Brows rise and slant as it worries.
        let lift: CGFloat = mood == .calm ? 0 : mood == .nervous ? 1.5 : 3.5
        var brows = Path()
        brows.move(to: CGPoint(x: 25, y: 47.5 - lift * 0.4))
        brows.addQuadCurve(to: CGPoint(x: 43, y: 46.5 - lift), control: CGPoint(x: 34, y: 42.5 - lift))
        brows.move(to: CGPoint(x: 58, y: 46.5 - lift))
        brows.addQuadCurve(to: CGPoint(x: 75, y: 49.5 - lift * 0.3), control: CGPoint(x: 66, y: 42.5 - lift))
        c.stroke(brows, with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))

        // Blink every few seconds, unless it's too panicked to.
        let phase = t.truncatingRemainder(dividingBy: 4.3)
        let blink = (still || mood == .panicking || phase > 0.18) ? 0 : sin(phase / 0.18 * .pi)
        let eyes: [(CGPoint, CGFloat)] = [(CGPoint(x: 35, y: 61), mood == .panicking ? 13.5 : 12.5),
                                          (CGPoint(x: 66, y: 62), mood == .panicking ? 11.5 : 10.5)]
        for (i, (eye, r)) in eyes.enumerated() {
            let open = max(0.08, 1 - blink)
            let ring = CGRect(x: eye.x - r, y: eye.y - r * open, width: r * 2, height: r * 2 * open)
            let ringPath = Path(ellipseIn: ring)
            c.fill(ringPath, with: .color(.white))
            var inner = c
            inner.clip(to: ringPath)
            let pr = r * (mood == .panicking ? 0.42 : 0.5)
            let look = pupils.indices.contains(i) ? pupils[i] : .zero
            let travel = r - pr - 1.2
            let pc = CGPoint(x: eye.x + look.x * travel, y: eye.y + look.y * travel)
            inner.fill(Path(ellipseIn: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2)), with: .color(ink))
            inner.fill(Path(ellipseIn: CGRect(x: pc.x + pr * 0.15, y: pc.y - pr * 0.65, width: pr * 0.5, height: pr * 0.5)),
                       with: .color(.white))
            c.stroke(ringPath, with: .color(ink), lineWidth: 2.2)
        }

        // Rosy cheeks.
        for x in [24.0, 77.0] {
            c.fill(Path(ellipseIn: CGRect(x: x - 5.5, y: 74, width: 11, height: 5.5)), with: .color(blush.opacity(0.6)))
        }

        drawMouth(in: &c, mood: mood, time: t, still: still)
        drawSweat(in: &c, mood: mood, time: t, still: still)
    }

    private static func drawMouth(in c: inout GraphicsContext, mood: Mood, time t: TimeInterval, still: Bool) {
        switch mood {
        case .calm:
            var smile = Path()
            smile.move(to: CGPoint(x: 42, y: 78))
            smile.addQuadCurve(to: CGPoint(x: 58, y: 78), control: CGPoint(x: 50, y: 86))
            c.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        case .nervous:
            let o = CGRect(x: 46.5, y: 77, width: 7, height: 6.5)
            c.fill(Path(ellipseIn: o), with: .color(throat))
            c.stroke(Path(ellipseIn: o), with: .color(ink), lineWidth: 1.6)
        case .panicking:
            let open = still ? 1 : 0.9 + sin(t * 18) * 0.1
            var mouth = Path()
            mouth.move(to: CGPoint(x: 39, y: 76))
            mouth.addLine(to: CGPoint(x: 61, y: 75))
            mouth.addQuadCurve(to: CGPoint(x: 39, y: 76), control: CGPoint(x: 49, y: 76 + 20 * open))
            mouth.closeSubpath()
            c.fill(mouth, with: .color(throat))
            var inner = c
            inner.clip(to: mouth)
            inner.fill(Path(ellipseIn: CGRect(x: 42, y: 80 + 4 * open, width: 15, height: 10)), with: .color(tongue))
            c.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }

    private static func drawSweat(in c: inout GraphicsContext, mood: Mood, time t: TimeInterval, still: Bool) {
        let drops: [(x: CGFloat, y: CGFloat, size: CGFloat)] = switch mood {
        case .calm: []
        case .nervous: [(96, 26, 1)]
        case .panicking: [(98, 20, 1.1), (2, 30, 0.9), (100, 50, 0.75)]
        }
        for (i, d) in drops.enumerated() {
            let fall = still ? 0 : CGFloat((t * 0.9 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1))
            let y = d.y + fall * 10
            var drop = Path()
            let s = d.size * 5
            drop.move(to: CGPoint(x: d.x, y: y - s * 1.4))
            drop.addCurve(to: CGPoint(x: d.x, y: y + s), control1: CGPoint(x: d.x - s * 0.3, y: y - s * 0.4),
                          control2: CGPoint(x: d.x - s, y: y + s))
            drop.addCurve(to: CGPoint(x: d.x, y: y - s * 1.4), control1: CGPoint(x: d.x + s, y: y + s),
                          control2: CGPoint(x: d.x + s * 0.3, y: y - s * 0.4))
            var dc = c
            dc.opacity = still ? 1 : 1 - Double(fall) * 0.7
            dc.fill(drop, with: .color(sky))
            dc.fill(Path(ellipseIn: CGRect(x: d.x - s * 0.45, y: y, width: s * 0.35, height: s * 0.5)), with: .color(.white.opacity(0.8)))
        }
    }

    private static func drawSpeedLines(in c: inout GraphicsContext, time t: TimeInterval, still: Bool) {
        for (i, y) in [52.0, 63.0, 74.0].enumerated() {
            let wobble = still ? 0 : sin(t * 9 + Double(i)) * 2
            var line = Path()
            line.move(to: CGPoint(x: -14 + wobble, y: y))
            line.addLine(to: CGPoint(x: -3 + wobble, y: y - 0.6))
            c.stroke(line, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
    }
}
