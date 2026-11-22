import SwiftUI
import ClamDownAppKit

/// An icon style's glyph for settings screens: the drawn image for the Lid, an SF Symbol for the rest, at the text
/// size around it. With a `size`, the menu bar image itself drawn at that size, not scaled afterwards, so it takes its
/// real room in the layout.
struct MenuBarIconGlyph: View {
    let symbol: String
    var size: CGFloat?

    var body: some View {
        if let size {
            Image(nsImage: MenuBarIconImage.base(symbol: symbol) ?? NSImage())
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
        } else if let image = MenuBarIconImage.base(symbol: symbol), symbol.hasPrefix("clamdown.") {
            Image(nsImage: image)
        } else {
            Image(systemName: symbol)
        }
    }
}
