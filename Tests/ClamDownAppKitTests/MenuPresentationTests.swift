import Testing
@testable import ClamDownAppKit

@Suite struct MenuPresentationTests {
    @Test func offState() {
        #expect(MenuPresentation(state: .off, notice: nil)
            == MenuPresentation(symbolName: "clamdown.lid", toggleTitle: "Turn On", statusLine: nil))
    }

    @Test func onState() {
        let p = MenuPresentation(state: .on, notice: nil)
        #expect(p.symbolName == "clamdown.lid.fill" && p.toggleTitle == "Turn Off" && p.statusLine == nil)
    }

    @Test func approvalState() {
        let p = MenuPresentation(state: .needsApproval, notice: nil)
        #expect(p.statusLine == "Approve ClamDown in System Settings > Login Items")
        #expect(p.symbolName == "clamdown.lid" && p.toggleTitle == "Turn On")
    }

    @Test func attentionBadge() {
        #expect(MenuPresentation(state: .off, notice: nil, helperReady: false).needsAttention)
        #expect(MenuPresentation(state: .failed("boom"), notice: nil).needsAttention)
        #expect(MenuPresentation(state: .needsApproval, notice: nil).needsAttention)
        #expect(!MenuPresentation(state: .off, notice: "Turned off: battery at 10%.").needsAttention)
        #expect(!MenuPresentation(state: .on, notice: nil).needsAttention)
    }

    /// A failure with nothing to press under it leaves the user guessing.
    @Test func failedOffersToTryAgain() {
        #expect(MenuPresentation(state: .failed("boom"), notice: nil).toggleTitle == "Try Again")
    }

    @Test func failureWithAWorkingRegistrationOffersToReinstallTheHelper() {
        #expect(MenuPresentation(state: .failed("boom"), notice: nil).recovery == .reinstallHelper)
    }

    @Test func helperThatIsNotAllowedOffersSetup() {
        #expect(MenuPresentation(state: .failed("boom"), notice: nil, helperReady: false).recovery == .finishSetup)
        #expect(MenuPresentation(state: .off, notice: nil, helperReady: false).recovery == .finishSetup)
        #expect(MenuPresentation(state: .on, notice: nil, helperReady: false).recovery == .finishSetup)
        #expect(MenuPresentation(state: .needsApproval, notice: nil).recovery == .finishSetup)
    }

    @Test func nothingToRecoverWhenAllIsWell() {
        #expect(MenuPresentation(state: .off, notice: nil).recovery == nil)
        #expect(MenuPresentation(state: .on, notice: nil).recovery == nil)
        #expect(MenuPresentation(state: .off, notice: "Turned off: battery at 10%.").recovery == nil)
    }

    /// The Mac still stays awake and macOS cools it, so the icon gets no attention mark.
    @Test func coolingLineIsShownWithoutAttentionMark() {
        let line = "ClamDown is not controlling the fans: cannot open the SMC. macOS has them."
        let p = MenuPresentation(state: .on, notice: nil, coolingLine: line)
        #expect(p.coolingLine == line)
        #expect(!p.needsAttention)
        #expect(p.statusLine == nil)
        #expect(p.accessibilityLabel == "ClamDown, on")
    }

    @Test func coolingLineOnlyWhileOn() {
        #expect(MenuPresentation(state: .off, notice: nil, coolingLine: "x").coolingLine == nil)
    }

    @Test func failedShowsMessage() {
        #expect(MenuPresentation(state: .failed("boom"), notice: nil).statusLine == "boom")
    }

    @Test func noticeShownWhenOff() {
        #expect(MenuPresentation(state: .off, notice: "Turned off: battery at 10%.").statusLine == "Turned off: battery at 10%.")
    }

    @Test func noticeShownWhileOn() {
        let p = MenuPresentation(state: .on, notice: "Could not turn off: gone")
        #expect(p.statusLine == "Could not turn off: gone" && p.toggleTitle == "Turn Off")
    }
}

@Suite struct MenuPresentationIconTests {
    @Test func iconStyleChangesTheSymbol() {
        #expect(MenuPresentation(state: .off, notice: nil, icon: .bolt).symbolName == "bolt")
        #expect(MenuPresentation(state: .on, notice: nil, icon: .bolt).symbolName == "bolt.fill")
        #expect(MenuPresentation(state: .failed("x"), notice: nil, icon: .sun).symbolName == "sun.max")
    }
}

/// What VoiceOver reads for the menu bar item, the app's only entry point.
@Suite struct MenuPresentationAccessibilityTests {
    @Test func saysTheAppAndWhetherItIsOn() {
        #expect(MenuPresentation(state: .on, notice: nil).accessibilityLabel == "ClamDown, on")
        #expect(MenuPresentation(state: .off, notice: nil).accessibilityLabel == "ClamDown, off")
        #expect(MenuPresentation(state: .off, notice: "Turned off: battery at 10%.").accessibilityLabel == "ClamDown, off")
    }

    @Test func saysWhenItNeedsAttention() {
        #expect(MenuPresentation(state: .on, notice: nil, helperReady: false).accessibilityLabel
            == "ClamDown, on, needs attention")
        #expect(MenuPresentation(state: .off, notice: nil, helperReady: false).accessibilityLabel
            == "ClamDown, off, needs attention")
        #expect(MenuPresentation(state: .needsApproval, notice: nil).accessibilityLabel
            == "ClamDown, off, needs attention")
        #expect(MenuPresentation(state: .failed("boom"), notice: nil).accessibilityLabel
            == "ClamDown, off, needs attention")
    }

    @Test(arguments: MenuBarIconStyle.allCases) func theSameForEveryIconStyle(style: MenuBarIconStyle) {
        #expect(MenuPresentation(state: .on, notice: nil, icon: style).accessibilityLabel == "ClamDown, on")
    }
}
