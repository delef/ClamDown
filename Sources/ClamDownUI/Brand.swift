import AppKit
import SwiftUI

/// A settings icon as System Settings draws them: a white SF Symbol on a rounded square of one colour, a little
/// lighter at the top.
public struct CDSettingsIcon: View {
    private let symbol: String
    private let color: Color
    private let size: CGFloat

    public init(symbol: String, color: Color, size: CGFloat = 20) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(.white)
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
