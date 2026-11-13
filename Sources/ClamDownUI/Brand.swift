import AppKit
import SwiftUI

/// A rounded tile in the brand gradient with a white SF Symbol: the identity of a settings page.
public struct CDBrandTile: View {
    private let symbol: String
    private let size: CGFloat

    public init(symbol: String, size: CGFloat = CDMetric.tileSize) {
        self.symbol = symbol
        self.size = size
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * CDMetric.tileRadius / CDMetric.tileSize, style: .continuous)
        shape
            .fill(CDColor.brandGradient)
            .overlay {
                // The light edge along the top of the tile.
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 1)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: CDColor.brandNavy.opacity(0.25), radius: size * 0.12, y: size * 0.07)
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
                    Ellipse()
                        .fill(RadialGradient(colors: [CDColor.brandMintGlow.opacity(0.4), .clear],
                                             center: .center, startRadius: 0, endRadius: size * 1.3))
                        .frame(width: size * 2.6, height: size * 1.7)
                        .blur(radius: 10)
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
