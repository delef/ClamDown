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
    public static let tileSize: CGFloat = 46
    public static let tileRadius: CGFloat = 12
    public static let pageSpacing: CGFloat = 22
    public static let rowSpacing: CGFloat = 10
    /// The size of a switch in a settings row. macOS 14 and later draw the large switch; macOS 13 stays regular.
    public static let switchControlSize: ControlSize = .large
}
