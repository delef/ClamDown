// Draws the DMG window background: a soft gradient, a pad under each icon slot, a curved arrow
// from the app to Applications, and a caption. make-dmg.sh places the icons to match.
// Usage: swift scripts/dmg-background.swift <out.png> <scale>
// Regenerate Resources/dmg/background.tiff with:
//   swift scripts/dmg-background.swift /tmp/bg.png 1 && swift scripts/dmg-background.swift /tmp/bg@2x.png 2
//   tiffutil -cathidpicheck /tmp/bg.png /tmp/bg@2x.png -out Resources/dmg/background.tiff
import AppKit

let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2])!)
let size = CGSize(width: 720, height: 460)
// Icon centers in Finder coordinates (origin top-left); keep in sync with make-dmg.sh.
let appCenter = CGPoint(x: 190, y: 215)
let appsCenter = CGPoint(x: 530, y: 215)

func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y) }
func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: near-white at the top to a pale mint-blue at the bottom.
NSGradient(colors: [srgb(0.985, 0.99, 1.0), srgb(0.91, 0.965, 0.965), srgb(0.86, 0.93, 0.96)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: -90)

// Soft pads under the two icon slots.
for center in [appCenter, appsCenter] {
    let c = flip(center)
    let pad = NSRect(x: c.x - 105, y: c.y - 118, width: 210, height: 220)
    let path = NSBezierPath(roundedRect: pad, xRadius: 36, yRadius: 36)
    let shadow = NSShadow()
    shadow.shadowColor = srgb(0.10, 0.30, 0.40, 0.12)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    srgb(1, 1, 1, 0.55).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    srgb(1, 1, 1, 0.9).setStroke()
    path.lineWidth = 1
    path.stroke()
}

// Curved arrow between the pads, rising slightly in the middle.
let start = flip(CGPoint(x: 312, y: 200))
let end = flip(CGPoint(x: 404, y: 200))
let control = flip(CGPoint(x: 358, y: 162))
let arc = NSBezierPath()
arc.move(to: start)
arc.curve(to: end, controlPoint1: control, controlPoint2: control)
arc.lineWidth = 7
arc.lineCapStyle = .round
let green = srgb(0.13, 0.70, 0.52)
green.setStroke()
arc.stroke()
// Arrowhead aligned with the curve's end tangent.
let angle = atan2(end.y - control.y, end.x - control.x)
let headLength: CGFloat = 20, spread: CGFloat = .pi / 5
let head = NSBezierPath()
head.move(to: CGPoint(x: end.x - headLength * cos(angle - spread), y: end.y - headLength * sin(angle - spread)))
head.line(to: end)
head.line(to: CGPoint(x: end.x - headLength * cos(angle + spread), y: end.y - headLength * sin(angle + spread)))
head.lineWidth = 7
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// Caption.
let para = NSMutableParagraphStyle()
para.alignment = .center
("Drag ClamDown into Applications" as NSString).draw(
    in: NSRect(x: 0, y: 46, width: size.width, height: 26),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: srgb(0.16, 0.24, 0.30),
        .paragraphStyle: para,
    ])

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
