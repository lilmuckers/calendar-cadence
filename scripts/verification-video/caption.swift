// Renders a caption as a transparent 1920×1080 PNG for scripts/verification-video/assemble.sh.
//   swift caption.swift lower "calendar.events: replying to an invite" out.png
//   swift caption.swift card  "Title\nSubtitle line" out.png      (full-frame title card, opaque)
import AppKit

let args = CommandLine.arguments
guard args.count == 4, ["lower", "card"].contains(args[1]) else {
    FileHandle.standardError.write("usage: caption.swift lower|card <text> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let mode = args[1], text = args[2].replacingOccurrences(of: "\\n", with: "\n"), out = args[3]
let size = NSSize(width: 1920, height: 1080)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let para = NSMutableParagraphStyle()
para.alignment = .center
para.lineSpacing = 8

if mode == "card" {
    NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    let lines = text.components(separatedBy: "\n")
    let body = NSMutableAttributedString(string: lines[0], attributes: [
        .font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: para,
    ])
    if lines.count > 1 {
        body.append(NSAttributedString(string: "\n\n" + lines.dropFirst().joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: 36, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.75), .paragraphStyle: para,
        ]))
    }
    let box = body.boundingRect(with: NSSize(width: 1600, height: 1000), options: [.usesLineFragmentOrigin])
    body.draw(with: NSRect(x: 160, y: (size.height - box.height) / 2, width: 1600, height: box.height),
              options: [.usesLineFragmentOrigin])
} else {
    let body = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para,
    ])
    let box = body.boundingRect(with: NSSize(width: 1600, height: 400), options: [.usesLineFragmentOrigin])
    let pad = NSSize(width: 36, height: 20)
    let w = ceil(box.width) + pad.width * 2, h = ceil(box.height) + pad.height * 2
    let plate = NSRect(x: (size.width - w) / 2, y: 60, width: w, height: h)
    NSColor(white: 0, alpha: 0.78).setFill()
    NSBezierPath(roundedRect: plate, xRadius: 18, yRadius: 18).fill()
    body.draw(with: plate.insetBy(dx: pad.width, dy: pad.height), options: [.usesLineFragmentOrigin])
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
