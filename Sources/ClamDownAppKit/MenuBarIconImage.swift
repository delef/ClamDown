import AppKit

/// Draws the menu bar icon, with an attention mark when ClamDown cannot work until the user acts.
public enum MenuBarIconImage {
    /// The names of the Lid icon, which the app draws itself instead of taking an SF Symbol.
    private static let lidOff = "clamdown.lid"
    private static let lidOn = "clamdown.lid.fill"

    /// The icon for a symbol name: the drawn Lid for its two names, an SF Symbol at the menu bar's 13 pt otherwise.
    /// A template image, so macOS colors it for a light or a dark menu bar. VoiceOver reads it as "ClamDown"; the
    /// menu bar item adds the state on top (`MenuPresentation.accessibilityLabel`).
    public static func base(symbol: String) -> NSImage? {
        let image: NSImage? = switch symbol {
        case lidOff: lid(on: false)
        case lidOn: lid(on: true)
        default:
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        }
        image?.accessibilityDescription = accessibilityName
        return image
    }

    /// The name VoiceOver reads for a plain icon.
    private static let accessibilityName = "ClamDown"

    /// The Lid on an 18 x 18 pt canvas, from the paths of the approved sketch (an 18 x 18 view box, y down).
    /// Off is a rounded outline with a flat line; on is the filled lid with a heartbeat cut out of it.
    private static func lid(on: Bool) -> NSImage {
        let height: CGFloat = 18
        // The sketch's y axis points down, AppKit's up.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: height - y) }

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            if on {
                let path = NSBezierPath()
                path.windingRule = .evenOdd
                let body = NSRect(x: 1.6, y: height - 15.1, width: 14.8, height: 12.2)
                path.appendRoundedRect(body, xRadius: 3.3, yRadius: 3.3)
                path.append(pulse(point: point))
                path.fill()
            } else {
                let outline = NSBezierPath(roundedRect: NSRect(x: 2.3, y: height - 14.4, width: 13.4, height: 10.8),
                                           xRadius: 2.6, yRadius: 2.6)
                outline.lineWidth = 1.4
                outline.stroke()
                let line = NSBezierPath()
                line.move(to: point(5.4, 9))
                line.line(to: point(12.6, 9))
                line.lineWidth = 1.4
                line.lineCapStyle = .round
                line.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The heartbeat line as a closed shape 1.3 wide: flat, a rise, a fall below the line, a rise back, flat.
    private static func pulse(point: (CGFloat, CGFloat) -> NSPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(4.5, 8.4))
        path.cap(from: point(4.5, 8.4), to: point(4.5, 9.7))
        path.line(to: point(6.8, 9.7))
        path.cap(from: point(6.8, 9.7), to: point(7.4, 9.3))
        path.line(to: point(7.9, 8.0))
        path.line(to: point(9.0, 11.6))
        path.cap(from: point(9.0, 11.6), to: point(10.2, 11.7))
        path.line(to: point(11.2, 9.7))
        path.line(to: point(13.5, 9.7))
        path.cap(from: point(13.5, 9.7), to: point(13.5, 8.4))
        path.line(to: point(10.8, 8.4))
        path.cap(from: point(10.8, 8.4), to: point(10.2, 8.8))
        path.line(to: point(9.7, 9.8))
        path.line(to: point(8.6, 6.1))
        path.cap(from: point(8.6, 6.1), to: point(7.4, 6.0))
        path.line(to: point(6.4, 8.4))
        path.close()
        return path
    }

    /// The symbol with a small exclamation badge at its lower right corner.
    /// A template image, so macOS colors it for a light or a dark menu bar like any other status icon.
    public static func attention(symbol: String) -> NSImage {
        // `base` draws at 13 pt, which is what SwiftUI uses for a plain `Image(systemName:)` in the menu bar, so the
        // icon keeps its size when the mark appears.
        let badgeConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        guard let base = base(symbol: symbol),
              let badge = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(badgeConfiguration)
        else { return NSImage() }

        // The badge sits on the symbol's lower right corner and mostly outside it: placed further in, the clear ring
        // around it cuts thin strokes (a bolt's tip, a cup's handle) into loose fragments.
        let overhangX = (badge.size.width * 0.6).rounded()
        let overhangY = (badge.size.height * 0.35).rounded()
        let size = NSSize(width: base.size.width + overhangX, height: base.size.height + overhangY)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: overhangY, width: base.size.width, height: base.size.height))
            let badgeRect = NSRect(x: size.width - badge.size.width, y: 0, width: badge.size.width, height: badge.size.height)
            // A clear ring keeps the badge apart from the symbol's lines it does cross.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.25, dy: -1.25)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            badge.draw(in: badgeRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ClamDown needs attention"
        return image
    }
}

private extension NSBezierPath {
    /// A round end of a stroke: the minor arc of radius .65 counter-clockwise from `start` to `end`, as the sketch's
    /// `a.65.65 0 0 0` draws it in a view box whose y axis points down.
    func cap(from start: NSPoint, to end: NSPoint) {
        let radius: CGFloat = 0.65
        let dx = end.x - start.x, dy = end.y - start.y
        let chord = (dx * dx + dy * dy).squareRoot()
        // The center sits left of the direction of travel, `offset` away from the middle of the chord.
        let offset = (radius * radius - chord * chord / 4).squareRoot()
        let center = NSPoint(x: (start.x + end.x) / 2 - dy / chord * offset,
                             y: (start.y + end.y) / 2 + dx / chord * offset)
        func degrees(_ p: NSPoint) -> CGFloat { atan2(p.y - center.y, p.x - center.x) * 180 / .pi }
        appendArc(withCenter: center, radius: radius, startAngle: degrees(start), endAngle: degrees(end), clockwise: false)
    }
}
