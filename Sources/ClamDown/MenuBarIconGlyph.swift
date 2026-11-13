import SwiftUI
import ClamDownAppKit

/// An icon style's glyph for settings screens: the drawn image for the Lid, an SF Symbol for the rest.
struct MenuBarIconGlyph: View {
    let symbol: String

    var body: some View {
        if let image = MenuBarIconImage.base(symbol: symbol), symbol.hasPrefix("clamdown.") {
            Image(nsImage: image)
        } else {
            Image(systemName: symbol)
        }
    }
}
