import AppKit
import Testing
@testable import ClamDownAppKit

@Suite struct MenuBarIconImageTests {
    private static let symbols = MenuBarIconStyle.allCases.flatMap { [$0.offSymbol, $0.onSymbol] }

    @Test(arguments: symbols) func everyStyleDrawsABaseImage(symbol: String) throws {
        let image = try #require(MenuBarIconImage.base(symbol: symbol), "no image for \(symbol)")
        #expect(image.size.width > 0 && image.size.height > 0 && image.isTemplate)
    }

    @Test(arguments: symbols, [MenuIconBadge.attention, .timer])
    func everyStyleDrawsWithEachMark(symbol: String, badge: MenuIconBadge) throws {
        let base = try #require(MenuBarIconImage.base(symbol: symbol))
        let image = MenuBarIconImage.badged(symbol: symbol, badge: badge)
        #expect(image.size.width > base.size.width && image.size.height > base.size.height && image.isTemplate)
    }

    /// VoiceOver needs a name for the image itself too, the drawn Lid included.
    @Test(arguments: symbols) func everyBaseImageIsNamedForVoiceOver(symbol: String) throws {
        let image = try #require(MenuBarIconImage.base(symbol: symbol))
        #expect(image.accessibilityDescription == "ClamDown")
    }

    @Test func anUnknownSymbolGivesNoImage() {
        #expect(MenuBarIconImage.base(symbol: "clamdown.no-such-icon") == nil)
    }
}
