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

    // MARK: Charts

    /// The cool end of the heat scale: #2F7CF6 in light appearance, #4C93FF in dark.
    public static let chartCool = dynamic(light: heatLight[0], dark: heatDark[0])
    /// The middle of the heat scale: #F0A020 in light appearance, #F5B03A in dark.
    public static let chartWarm = dynamic(light: heatLight[1], dark: heatDark[1])
    /// The hot end of the heat scale: #E5484D in light appearance, #FF6166 in dark.
    public static let chartHot = dynamic(light: heatLight[2], dark: heatDark[2])
    /// Where amber sits on the heat scale, as a fraction from the cool end.
    public static let chartWarmLocation = 0.55

    /// Blue through amber to red, from the cool end of a chart to the hot one.
    public static var chartHeatStops: [Gradient.Stop] {
        [.init(color: chartCool, location: 0), .init(color: chartWarm, location: chartWarmLocation),
         .init(color: chartHot, location: 1)]
    }

    /// The heat scale at one place, 0 at the cool end and 1 at the hot one, for marks that need a single colour.
    public static func chartHeat(at fraction: Double) -> Color {
        let fraction = min(max(fraction, 0), 1)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let stops = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? heatDark : heatLight
            let lowerHalf = fraction < chartWarmLocation
            let (from, to) = lowerHalf ? (stops[0], stops[1]) : (stops[1], stops[2])
            let k = lowerHalf ? fraction / chartWarmLocation : (fraction - chartWarmLocation) / (1 - chartWarmLocation)
            func mix(_ a: Int, _ b: Int) -> CGFloat { (CGFloat(a) + CGFloat(b - a) * k) / 255 }
            return NSColor(srgbRed: mix(from.0, to.0), green: mix(from.1, to.1), blue: mix(from.2, to.2), alpha: 1)
        })
    }

    /// A zone of a chart that is out of bounds, such as the fans' safety floor: grey at 16 %.
    public static let chartZone = dynamic(light: (120, 120, 128), dark: (160, 160, 170), alpha: 0.16)
    /// The hatching and the label of such a zone: #8A8A90 in light appearance, #8E8E93 in dark.
    public static let chartZoneInk = dynamic(light: (0x8A, 0x8A, 0x90), dark: (0x8E, 0x8E, 0x93))
    /// The grid lines of a chart: black at 9 % in light appearance, white at 10 % in dark.
    public static let chartGrid = dynamic(light: (0, 0, 0), dark: (255, 255, 255), alpha: (0.09, 0.10))
    /// The fill of a draggable point on a chart: white in light appearance, #1F1F21 in dark.
    public static let chartHandle = dynamic(light: (0xFF, 0xFF, 0xFF), dark: (0x1F, 0x1F, 0x21))

    private static let heatLight = [(0x2F, 0x7C, 0xF6), (0xF0, 0xA0, 0x20), (0xE5, 0x48, 0x4D)]
    private static let heatDark = [(0x4C, 0x93, 0xFF), (0xF5, 0xB0, 0x3A), (0xFF, 0x61, 0x66)]

    /// A colour that follows the appearance of the view it is drawn in.
    static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int), alpha: Double = 1) -> Color {
        dynamic(light: light, dark: dark, alpha: (alpha, alpha))
    }

    static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int), alpha: (light: Double, dark: Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
                           alpha: isDark ? alpha.dark : alpha.light)
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

    /// The plot of a chart, without its axis labels.
    public static let chartHeight: CGFloat = 196
    /// A chart's main line.
    public static let chartLineWidth: CGFloat = 3
    /// The round handle of a point that can be dragged, and the area that picks it up.
    public static let chartHandleRadius: CGFloat = 7.5
    public static let chartHandleHitSize: CGFloat = 26
    /// The small label over a point while it is dragged.
    public static let chartLabelRadius: CGFloat = 6
}
