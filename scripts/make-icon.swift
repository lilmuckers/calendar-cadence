// Draws the Cadence app icon: a panicking calendar page with googly eyes, late for a meeting.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func shadow(_ blur: CGFloat, y: CGFloat, _ c: NSColor) {
    ctx.setShadow(offset: CGSize(width: 0, height: y), blur: blur, color: c.cgColor)
}

// --- Background squircle (Apple's 824pt grid inside 1024) ---
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 186, yRadius: 186)
ctx.saveGState()
shadow(28, y: -12, color(0x000000, 0.35))
color(0x7B2FF7).setFill()
bg.fill()
ctx.restoreGState()
ctx.saveGState()
bg.addClip()
NSGradient(colors: [color(0xFF5E8A), color(0xFF9A3C), color(0xFFD23F)])!
    .draw(in: bgRect, angle: -60)
// Comic "panic" burst rays
ctx.translateBy(x: 512, y: 470)
for i in 0..<16 {
    ctx.saveGState()
    ctx.rotate(by: CGFloat(i) * .pi / 8)
    let ray = NSBezierPath()
    ray.move(to: .zero)
    ray.line(to: CGPoint(x: -70, y: 700))
    ray.line(to: CGPoint(x: 70, y: 700))
    ray.close()
    color(0xFFFFFF, 0.10).setFill()
    ray.fill()
    ctx.restoreGState()
}
ctx.restoreGState()

// --- Calendar page, tilted like it's running away ---
ctx.saveGState()
ctx.translateBy(x: 512, y: 480)
ctx.rotate(by: -0.10)

let page = CGRect(x: -270, y: -250, width: 540, height: 500)
let pagePath = NSBezierPath(roundedRect: page, xRadius: 70, yRadius: 70)
ctx.saveGState()
shadow(40, y: -22, color(0x5A1030, 0.45))
color(0xFFFFFF).setFill()
pagePath.fill()
ctx.restoreGState()

// Red header band
ctx.saveGState()
pagePath.addClip()
color(0xFF3B47).setFill()
CGRect(x: page.minX, y: page.maxY - 122, width: page.width, height: 122).fill()
// subtle page lines
color(0xEDE7F6).setFill()
for row in 0..<3 {
    CGRect(x: page.minX + 40, y: page.minY + 55 + CGFloat(row) * 4, width: page.width - 80, height: 0).fill()
}
ctx.restoreGState()

// "LATE!" in the header
let para = NSMutableParagraphStyle()
para.alignment = .center
let font = NSFont.systemFont(ofSize: 88, weight: .black)
let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: 88) ?? font
let late = NSAttributedString(string: "LATE!", attributes: [
    .font: rounded, .foregroundColor: NSColor.white, .paragraphStyle: para, .kern: 4,
])
late.draw(in: CGRect(x: page.minX, y: page.maxY - 118, width: page.width, height: 110))

// Binder rings poking out the top
for x in [-150.0, 150.0] {
    let ring = NSBezierPath(roundedRect: CGRect(x: x - 22, y: page.maxY - 40, width: 44, height: 110), xRadius: 22, yRadius: 22)
    color(0x3A3A4A).setFill()
    ring.fill()
    color(0x6E6E82).setFill()
    NSBezierPath(roundedRect: CGRect(x: x - 10, y: page.maxY - 20, width: 14, height: 80), xRadius: 7, yRadius: 7).fill()
}

// Googly eyes, pupils looking in different directions
func googly(_ c: CGPoint, r: CGFloat, look: CGVector) {
    let eye = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ctx.saveGState()
    shadow(10, y: -6, color(0x000000, 0.25))
    NSColor.white.setFill()
    eye.fill()
    ctx.restoreGState()
    color(0x1D1D2B).setStroke()
    eye.lineWidth = 9
    eye.stroke()
    let pr = r * 0.46
    let p = CGPoint(x: c.x + look.dx * (r - pr - 10), y: c.y + look.dy * (r - pr - 10))
    color(0x1D1D2B).setFill()
    NSBezierPath(ovalIn: CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2)).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: CGRect(x: p.x - pr * 0.15 + pr * 0.35, y: p.y + pr * 0.25, width: pr * 0.4, height: pr * 0.4)).fill()
}
googly(CGPoint(x: -100, y: -38), r: 88, look: CGVector(dx: 0.75, dy: 0.55))
googly(CGPoint(x: 110, y: -25), r: 74, look: CGVector(dx: -0.55, dy: -0.85))

// Worried eyebrows, slanted up toward the middle
func brow(from a: CGPoint, to b: CGPoint, bend: CGFloat) {
    let p = NSBezierPath()
    p.move(to: a)
    p.curve(to: b, controlPoint1: CGPoint(x: a.x + (b.x - a.x) / 3, y: a.y + bend),
            controlPoint2: CGPoint(x: a.x + 2 * (b.x - a.x) / 3, y: b.y + bend))
    p.lineWidth = 16
    p.lineCapStyle = .round
    color(0x1D1D2B).setStroke()
    p.stroke()
}
brow(from: CGPoint(x: -170, y: 72), to: CGPoint(x: -50, y: 104), bend: 12)
brow(from: CGPoint(x: 55, y: 106), to: CGPoint(x: 170, y: 78), bend: 12)

// Panicked open mouth with a wobbly tongue
ctx.saveGState()
ctx.translateBy(x: 0, y: -12)
ctx.scaleBy(x: 0.92, y: 0.92)
let mouth = NSBezierPath()
mouth.move(to: CGPoint(x: -85, y: -130))
mouth.curve(to: CGPoint(x: 85, y: -125), controlPoint1: CGPoint(x: -40, y: -105), controlPoint2: CGPoint(x: 40, y: -100))
mouth.curve(to: CGPoint(x: -85, y: -130), controlPoint1: CGPoint(x: 60, y: -235), controlPoint2: CGPoint(x: -60, y: -240))
mouth.close()
color(0x3B0A1E).setFill()
mouth.fill()
ctx.saveGState()
mouth.addClip()
color(0xFF6F91).setFill()
NSBezierPath(ovalIn: CGRect(x: -50, y: -235, width: 105, height: 75)).fill()
ctx.restoreGState()
color(0x1D1D2B).setStroke()
mouth.lineWidth = 8
mouth.stroke()

// Rosy cheeks
color(0xFF8FA3, 0.55).setFill()
NSBezierPath(ovalIn: CGRect(x: -225, y: -125, width: 70, height: 40)).fill()
NSBezierPath(ovalIn: CGRect(x: 170, y: -110, width: 70, height: 40)).fill()
ctx.restoreGState()

ctx.restoreGState() // end page transform

// Sweat drops flying off
func drop(_ c: CGPoint, _ s: CGFloat, angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: angle)
    ctx.scaleBy(x: s, y: s)
    let d = NSBezierPath()
    d.move(to: CGPoint(x: 0, y: 60))
    d.curve(to: CGPoint(x: 0, y: -40), controlPoint1: CGPoint(x: -10, y: 30), controlPoint2: CGPoint(x: -45, y: -40))
    d.curve(to: CGPoint(x: 0, y: 60), controlPoint1: CGPoint(x: 45, y: -40), controlPoint2: CGPoint(x: 10, y: 30))
    shadow(8, y: -4, color(0x000000, 0.2))
    color(0x4FC3FF).setFill()
    d.fill()
    NSColor.white.withAlphaComponent(0.8).setFill()
    NSBezierPath(ovalIn: CGRect(x: -14, y: -18, width: 12, height: 22)).fill()
    ctx.restoreGState()
}
drop(CGPoint(x: 815, y: 760), 1.1, angle: -0.5)
drop(CGPoint(x: 870, y: 640), 0.7, angle: -0.9)
drop(CGPoint(x: 205, y: 745), 0.8, angle: 0.5)

// Zoomy motion lines on the left
color(0xFFFFFF, 0.85).setStroke()
for (i, y) in [400.0, 470.0, 540.0].enumerated() {
    let l = NSBezierPath()
    l.move(to: CGPoint(x: 140 + CGFloat(i % 2) * 18, y: y))
    l.line(to: CGPoint(x: 205 + CGFloat(i % 2) * 18, y: y + 6))
    l.lineWidth = 14
    l.lineCapStyle = .round
    l.stroke()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
