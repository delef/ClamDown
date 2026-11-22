import AppKit
import Testing
@testable import ClamDownAppKit

@Suite struct MenuBarIconImageTests {
    private static let symbols = MenuBarIconStyle.allCases.flatMap { [$0.offSymbol, $0.onSymbol] }

    @Test(arguments: symbols) func everyStyleDrawsABaseImage(symbol: String) throws {
        let image = try #require(MenuBarIconImage.base(symbol: symbol), "no image for \(symbol)")
        #expect(image.size.width > 0 && image.size.height > 0 && image.isTemplate)
    }

    /// Each mark grows the icon and draws a mark of its own: the clock is not the attention mark.
    @Test(arguments: symbols) func everyStyleDrawsEachMark(symbol: String) throws {
        let base = try #require(MenuBarIconImage.base(symbol: symbol))
        let attention = MenuBarIconImage.badged(symbol: symbol, badge: .attention)
        let timer = MenuBarIconImage.badged(symbol: symbol, badge: .timer)
        for image in [attention, timer] {
            #expect(image.size.width > base.size.width && image.size.height > base.size.height && image.isTemplate)
        }
        #expect(try Self.pixels(attention) != Self.pixels(timer), "both marks draw the same for \(symbol)")
    }

    /// VoiceOver needs a name for the image itself too, the drawn Lid included.
    @Test(arguments: symbols) func everyBaseImageIsNamedForVoiceOver(symbol: String) throws {
        let image = try #require(MenuBarIconImage.base(symbol: symbol))
        #expect(image.accessibilityDescription == "ClamDown")
    }

    /// The image drawn at 2x into a bitmap, as its raw bytes.
    private static func pixels(_ image: NSImage) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) })
    }

    @Test func anUnknownSymbolGivesNoImage() {
        #expect(MenuBarIconImage.base(symbol: "clamdown.no-such-icon") == nil)
    }
}
