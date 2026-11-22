import AppKit
import SwiftUI

/// A settings icon as System Settings draws them: a white SF Symbol on a rounded square of one colour, a little
/// lighter at the top.
public struct CDSettingsIcon: View {
    private let symbol: String
    private let color: Color
    private let size: CGFloat

    /// The share of the tile the symbol fits into, on each side.
    private static let glyphShare: CGFloat = 0.6

    public init(symbol: String, color: Color, size: CGFloat = 20) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(color.gradient)
            .overlay {
                // Fitted into a box of a fixed share of the tile, not set by font size: a symbol at a small point size
                // is drawn larger and bolder for legibility, which filled a 20 pt sidebar tile almost to its edges
                // while the 56 pt page tile looked right. System Settings keeps the glyph to about 60 % at any size.
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .frame(width: size * Self.glyphShare, height: size * Self.glyphShare)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The app icon, optionally on a soft mint glow.
public struct CDAppIcon: View {
    private let size: CGFloat
    private let glow: Bool

    public init(size: CGFloat, glow: Bool = false) {
        self.size = size
        self.glow = glow
    }

    public var body: some View {
        Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: CDColor.brandNavy.opacity(0.3), radius: size * 0.14, y: size * 0.08)
            .background {
                if glow {
                    // Fades to clear well inside its frame, so there is no visible edge.
                    Rectangle()
                        .fill(RadialGradient(colors: [CDColor.brandMintGlow.opacity(0.4), .clear],
                                             center: .center, startRadius: 0, endRadius: size * 1.2))
                        .frame(width: size * 2.4, height: size * 2.4)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A 7 pt status dot with a soft ring of the same colour.
public struct CDStatusDot: View {
    private let color: Color

    public init(_ color: Color) {
        self.color = color
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(0.2)).padding(-3))
            .accessibilityHidden(true)
    }
}
