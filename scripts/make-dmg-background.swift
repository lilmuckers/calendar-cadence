// Draws the background for Cadence's DMG window: a warm burst, a title, and a hand-drawn
// arrow from the app (left) to the Applications folder (right).
// Usage: swift scripts/make-dmg-background.swift <output.png> [scale]
// Layout must match scripts/dmg-settings.py: 640×400 window, icons centred at (160, 200) and (480, 200).
import AppKit

let W: CGFloat = 640, H: CGFloat = 400
let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "dmg-background.png"
let scale: CGFloat = args.count > 2 ? CGFloat(Double(args[2]) ?? 1) : 1

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: W, height: H)  // points, so @2x renders sharper rather than bigger
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
// Finder coordinates are top-left; AppKit's are bottom-left.
func y(_ top: CGFloat) -> CGFloat { H - top }

// --- Background: pale version of the icon's pink → orange → yellow gradient ---
let full = CGRect(x: 0, y: 0, width: W, height: H)
NSGradient(colors: [color(0xFFF1F4), color(0xFFF4E8), color(0xFFFAE6)])!.draw(in: full, angle: -30)

// Soft burst rays from behind the arrow, echoing the icon.
ctx.saveGState()
ctx.translateBy(x: W / 2, y: y(200))
for i in 0..<20 {
    ctx.saveGState()
    ctx.rotate(by: CGFloat(i) * .pi / 10)
    let ray = NSBezierPath()
    ray.move(to: .zero)
    ray.line(to: CGPoint(x: -60, y: 520))
    ray.line(to: CGPoint(x: 60, y: 520))
    ray.close()
    color(0xFF9A3C, 0.06).setFill()
    ray.fill()
    ctx.restoreGState()
}
ctx.restoreGState()

// Light "stage" pads under each icon so they read as drop targets.
for cx in [160.0, 480.0] as [CGFloat] {
    let pad = NSBezierPath(roundedRect: CGRect(x: cx - 88, y: y(200) - 92, width: 176, height: 176),
                           xRadius: 36, yRadius: 36)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: color(0xC2410C, 0.12).cgColor)
    color(0xFFFFFF, 0.72).setFill()
    pad.fill()
    ctx.restoreGState()
}

// --- Title ---
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color c: NSColor, centreY top: CGFloat) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    let attrs: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: c]
    let s = NSAttributedString(string: text, attributes: attrs)
    let b = s.size()
    s.draw(at: CGPoint(x: (W - b.width) / 2, y: y(top) - b.height / 2))
}
draw("Install Cadence", size: 26, weight: .heavy, color: color(0x3B1D2E), centreY: 48)
draw("Drag it into Applications, then you're never late again.", size: 13, weight: .medium,
     color: color(0x7A4A5C), centreY: 78)

// --- Arrow: a slightly wobbly, hand-drawn swoop between the two icons ---
let start = CGPoint(x: 252, y: y(196)), end = CGPoint(x: 384, y: y(196))
let arrow = NSBezierPath()
arrow.move(to: start)
arrow.curve(to: end, controlPoint1: CGPoint(x: 290, y: y(150)), controlPoint2: CGPoint(x: 350, y: y(150)))
arrow.lineWidth = 7
arrow.lineCapStyle = .round
let dash: [CGFloat] = [0.1, 14]
arrow.setLineDash(dash, count: 2, phase: 0)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: color(0xE5484D, 0.25).cgColor)
// Gradient stroke: clip to the stroked path, then fill it.
ctx.addPath(arrow.cgPath.copy(dashingWithPhase: 0, lengths: dash).copy(
    strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 10))
ctx.clip()
NSGradient(colors: [color(0xFF5E8A), color(0xFF9A3C)])!
    .draw(in: CGRect(x: start.x - 10, y: y(220), width: end.x - start.x + 20, height: 90), angle: 0)
ctx.restoreGState()

// Arrow head, pointing along the curve's final direction (down-right into the folder).
ctx.saveGState()
ctx.translateBy(x: end.x, y: end.y)
ctx.rotate(by: atan2(end.y - y(150), end.x - 350))  // tangent at the end of the curve
let head = NSBezierPath()
head.move(to: CGPoint(x: -18, y: 13))
head.line(to: CGPoint(x: 4, y: 0))
head.line(to: CGPoint(x: -18, y: -13))
head.lineWidth = 7
head.lineCapStyle = .round
head.lineJoinStyle = .round
color(0xFF9A3C).setStroke()
head.stroke()
ctx.restoreGState()

// Speed lines behind the app, like the icon's.
for (i, dy) in ([-26, 0, 26] as [CGFloat]).enumerated() {
    let line = NSBezierPath()
    let len: CGFloat = i == 1 ? 26 : 18
    line.move(to: CGPoint(x: 34, y: y(200) + dy))
    line.line(to: CGPoint(x: 34 + len, y: y(200) + dy))
    line.lineWidth = 5
    line.lineCapStyle = .round
    color(0xFF9A3C, 0.45).setStroke()
    line.stroke()
}

// --- Footer ---
draw("Needs macOS 14 or later", size: 11, weight: .medium, color: color(0x7A4A5C, 0.75), centreY: 372)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
