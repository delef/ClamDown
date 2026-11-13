import AppKit

/// Draws the menu bar icon with an attention mark, for when ClamDown cannot work until the user acts.
enum MenuBarIconImage {
    /// The symbol with a small exclamation badge at its lower right corner.
    /// A template image, so macOS colors it for a light or a dark menu bar like any other status icon.
    static func attention(symbol: String) -> NSImage {
        // 13 pt is what SwiftUI draws for a plain `Image(systemName:)` in the menu bar, so the symbol keeps its size
        // when the mark appears.
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let badgeConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfiguration),
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
