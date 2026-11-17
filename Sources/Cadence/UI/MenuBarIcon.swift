import AppKit

/// Menu bar version of the app icon: a tiny calendar page with mismatched googly eyes.
/// Drawn as a template image so macOS tints it for light/dark menu bars.
enum MenuBarIcon {
    enum Mood { case calm, nervous, panicking }

    private static var cache: [Mood: NSImage] = [:]

    static func image(_ mood: Mood) -> NSImage {
        if let cached = cache[mood] { return cached }
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            draw(mood)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Cadence"
        cache[mood] = image
        return image
    }

    private static func draw(_ mood: Mood) {
        NSColor.black.set()
        let ctx = NSGraphicsContext.current!.cgContext

        // Slight tilt, like the big icon running late.
        ctx.translateBy(x: 9, y: 8.5)
        ctx.rotate(by: mood == .calm ? 0 : -0.08)
        ctx.translateBy(x: -9, y: -8.5)

        // Page outline with a filled header band.
        let page = NSRect(x: 1.5, y: 1, width: 14.5, height: 13.5)
        let outline = NSBezierPath(roundedRect: page, xRadius: 3, yRadius: 3)
        outline.lineWidth = 1.4
        outline.stroke()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSRect(x: page.minX, y: page.maxY - 3.2, width: page.width, height: 3.2).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Binder rings.
        for x in [5.0, 12.5] {
            NSBezierPath(roundedRect: NSRect(x: x - 0.9, y: page.maxY - 1.2, width: 1.8, height: 3.4), xRadius: 0.9, yRadius: 0.9).fill()
        }

        // Googly eyes: outlines only (transparent whites), pupils looking different ways.
        func eye(_ c: NSPoint, r: CGFloat, look: CGVector) {
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = 1.1
            ring.stroke()
            let pr = r * 0.48
            let p = NSPoint(x: c.x + look.dx * (r - pr - 0.5), y: c.y + look.dy * (r - pr - 0.5))
            NSBezierPath(ovalIn: NSRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2)).fill()
        }
        eye(NSPoint(x: 6, y: 7.4), r: 2.7, look: CGVector(dx: 0.7, dy: 0.6))
        eye(NSPoint(x: 11.8, y: 7.2), r: 2.3, look: CGVector(dx: -0.6, dy: -0.7))

        // Mouth: calm smile, nervous small "o", panicking big "O".
        switch mood {
        case .calm:
            let smile = NSBezierPath()
            smile.move(to: NSPoint(x: 7.4, y: 3.6))
            smile.curve(to: NSPoint(x: 10.6, y: 3.6), controlPoint1: NSPoint(x: 8.2, y: 2.4), controlPoint2: NSPoint(x: 9.8, y: 2.4))
            smile.lineWidth = 1.1
            smile.lineCapStyle = .round
            smile.stroke()
        case .nervous:
            NSBezierPath(ovalIn: NSRect(x: 8.1, y: 2.3, width: 1.9, height: 1.7)).fill()
        case .panicking:
            NSBezierPath(ovalIn: NSRect(x: 7.6, y: 1.9, width: 2.9, height: 2.6)).fill()
        }

        // Sweat drop when it's nearly time.
        if mood == .panicking {
            let d = NSBezierPath()
            d.move(to: NSPoint(x: 18.4, y: 15.6))
            d.curve(to: NSPoint(x: 18.4, y: 11.4), controlPoint1: NSPoint(x: 17.9, y: 14.2), controlPoint2: NSPoint(x: 16.8, y: 11.4))
            d.curve(to: NSPoint(x: 18.4, y: 15.6), controlPoint1: NSPoint(x: 20.0, y: 11.4), controlPoint2: NSPoint(x: 18.9, y: 14.2))
            d.fill()
        }
    }
}
