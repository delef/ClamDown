import AppKit

/// Draws the menu bar icon, with a mark in its corner: attention when ClamDown cannot work until the user acts,
/// a clock while it is on for a set time.
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
    private static let accessibilityName = String(localized: "ClamDown")

    /// The Lid on an 18 x 18 pt canvas: a closed laptop seen from the front, a slab with the notch of its lid.
    /// Off, the outline with a crescent moon above it: the Mac sleeps when the lid closes. On, the filled slab with
    /// rays above it: the closed Mac stays awake. Offered four concepts, the owner picked "awake" over a wedge-shaped
    /// lid and an eye (owner, 2026-11-22: "мне не нравится новая иконка lid, давай еще переделаем"); it replaced a lid
    /// with a heartbeat line. The moon replaced a "Z" the same day: the owner found the letter "слишком двухсмысленная" (owner,
    /// 2026-11-22); a moon is how macOS itself shows sleep.
    private static func lid(on: Bool) -> NSImage {
        let height: CGFloat = 18
        // The sketch's y axis points down, AppKit's up.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: height - y) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ rectHeight: CGFloat) -> NSRect {
            NSRect(x: x, y: height - y - rectHeight, width: width, height: rectHeight)
        }
        func strokes(_ lines: [(NSPoint, NSPoint)], width: CGFloat) {
            let path = NSBezierPath()
            for (from, to) in lines {
                path.move(to: from)
                path.line(to: to)
            }
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            if on {
                NSBezierPath(roundedRect: rect(1.5, 10.5, 15, 5), xRadius: 2.2, yRadius: 2.2).fill()
                // The notch is cut out of the slab, so it shows the menu bar through it.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(roundedRect: rect(7.6, 9.9, 2.8, 1.6), xRadius: 0.6, yRadius: 0.6).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                strokes([(point(9, 7.4), point(9, 3.6)), (point(11.3, 8.4), point(14.1, 6.2)),
                         (point(6.7, 8.4), point(3.9, 6.2))], width: 1.5)
            } else {
                let slab = NSBezierPath(roundedRect: rect(2.2, 11.2, 13.6, 3.6), xRadius: 1.7, yRadius: 1.7)
                slab.lineWidth = 1.4
                slab.stroke()
                NSBezierPath(roundedRect: rect(7.7, 11.4, 2.6, 1.1), xRadius: 0.5, yRadius: 0.5).fill()
                // A crescent: a disc with a smaller one taken out of its upper right.
                NSBezierPath(ovalIn: rect(5.9, 2.2, 6.2, 6.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: rect(8.0, 1.0, 5.4, 5.4)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The symbol with a small badge at its lower right corner: an exclamation mark or a clock.
    /// A template image, so macOS colors it for a light or a dark menu bar like any other status icon.
    public static func badged(symbol: String, badge mark: MenuIconBadge) -> NSImage {
        // `base` draws at 13 pt, which is what SwiftUI uses for a plain `Image(systemName:)` in the menu bar, so the
        // icon keeps its size when the mark appears.
        let badgeConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        let badgeSymbol = switch mark {
        case .attention: "exclamationmark.circle.fill"
        case .timer: "clock.fill"
        }
        guard let base = base(symbol: symbol),
              let badge = NSImage(systemSymbolName: badgeSymbol, accessibilityDescription: nil)?
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
        image.accessibilityDescription = switch mark {
        case .attention: String(localized: "ClamDown needs attention")
        case .timer: String(localized: "ClamDown, on for a set time")
        }
        return image
    }
}
