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
