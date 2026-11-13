import AppKit
import SwiftUI

/// ClamDown's colours: a handful of brand colours and the three status colours. Everything else is a system colour.
public enum CDColor {
    /// #0E2766, the dark end of the brand gradient.
    public static let brandNavy = Color(red: 0x0E / 255, green: 0x27 / 255, blue: 0x66 / 255)
    /// #1D8796, the light end of the brand gradient.
    public static let brandTeal = Color(red: 0x1D / 255, green: 0x87 / 255, blue: 0x96 / 255)
    /// #11896A in light appearance, #5FDCAA in dark.
    public static let brandMint = dynamic(light: (0x11, 0x89, 0x6A), dark: (0x5F, 0xDC, 0xAA))
    /// #6FF0B8, the glow behind the app icon.
    public static let brandMintGlow = Color(red: 0x6F / 255, green: 0xF0 / 255, blue: 0xB8 / 255)

    public static let success = Color.green
    public static let warning = Color.orange
    public static let danger = Color.red

    /// Warning as text: a dark orange (#B45309) in light appearance, where system orange is about 2:1 on a pale
    /// background; the system orange in dark. Symbols and dots keep `warning`.
    public static let warningText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.systemOrange : NSColor(srgbRed: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255, alpha: 1)
    })
    /// Success as text: a dark green (#15803D) in light appearance, the system green in dark.
    public static let successText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.systemGreen : NSColor(srgbRed: 0x15 / 255, green: 0x80 / 255, blue: 0x3D / 255, alpha: 1)
    })

    /// Danger as text: a dark red (#B91C1C) in light appearance, where system red is about 3.5:1 on the setup gradient;
    /// the system red in dark. Symbols, dots and the destructive button keep `danger`.
    public static let dangerText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.systemRed : NSColor(srgbRed: 0xB9 / 255, green: 0x1C / 255, blue: 0x1C / 255, alpha: 1)
    })

    /// The fill of a settings card: white in light appearance; in dark, the system's window colour with a little
    /// white on top, so a card is lighter than the window it sits on (the window colour follows the system).
    public static let cardBackground = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard isDark else { return .white }
        var result = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            let window = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
            result = window.blended(withFraction: 0.05, of: .white) ?? window
        }
        return result
    })

    /// The hairline around a settings card: black at 7 % in light appearance, white at 6 % in dark.
    public static let cardBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.06)
                                                                      : NSColor.black.withAlphaComponent(0.07)
    })

    /// Navy to teal, from the top leading corner to the bottom trailing one.
    public static var brandGradient: LinearGradient {
        LinearGradient(colors: [brandNavy, brandTeal], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A colour that follows the appearance of the view it is drawn in.
    static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        })
    }
}

/// ClamDown's sizes and spacings.
public enum CDMetric {
    public static let cardRadius: CGFloat = 12
    public static let setupCardRadius: CGFloat = 16
    public static let choiceTileRadius: CGFloat = 10
    public static let tileSize: CGFloat = 46
    public static let tileRadius: CGFloat = 12
    public static let cardInset: CGFloat = 16
    public static let cardRowPadding: CGFloat = 10
    public static let pageInset: CGFloat = 20
    public static let pageSpacing: CGFloat = 22
    public static let rowSpacing: CGFloat = 10
}
