import AppKit
import Testing
@testable import ClamDownAppKit

@Suite struct MenuBarIconImageTests {
    private static let symbols = MenuBarIconStyle.allCases.flatMap { [$0.offSymbol, $0.onSymbol] }

    @Test(arguments: symbols) func everyStyleDrawsABaseImage(symbol: String) throws {
        let image = try #require(MenuBarIconImage.base(symbol: symbol), "no image for \(symbol)")
        #expect(image.size.width > 0 && image.size.height > 0 && image.isTemplate)
    }

    @Test(arguments: symbols) func everyStyleDrawsWithTheAttentionMark(symbol: String) throws {
        let base = try #require(MenuBarIconImage.base(symbol: symbol))
        let image = MenuBarIconImage.attention(symbol: symbol)
        #expect(image.size.width > base.size.width && image.size.height > base.size.height && image.isTemplate)
    }

    @Test func anUnknownSymbolGivesNoImage() {
        #expect(MenuBarIconImage.base(symbol: "clamdown.no-such-icon") == nil)
    }
}
