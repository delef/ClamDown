import Testing
@testable import ClamDownAppKit

@Suite struct TurnOnProgressWindowTests {
    /// The quick Turn On, with a helper that answers at once, shows nothing: the blinking icon is enough.
    @Test func aQuickTurnOnOpensNothing() {
        var rule = TurnOnProgressWindow()
        #expect(rule.update(step: .starting, isOn: false, windowOpen: false) == .none)
        #expect(rule.update(step: nil, isOn: true, windowOpen: false) == .none)
    }

    @Test func settingUpTheHelperOpensTheWindowAndSuccessClosesIt() {
        var rule = TurnOnProgressWindow()
        #expect(rule.update(step: .starting, isOn: false, windowOpen: false) == .none)
        #expect(rule.update(step: .settingUpHelper, isOn: false, windowOpen: false) == .open)
        #expect(rule.update(step: .waitingForHelper, isOn: false, windowOpen: true) == .none)
        #expect(rule.update(step: nil, isOn: true, windowOpen: true) == .close)
    }

    /// A failure or a wait for approval stays on screen: the window then says what to do.
    @Test func aTurnOnThatDoesNotEndOnLeavesTheWindowOpen() {
        var rule = TurnOnProgressWindow()
        #expect(rule.update(step: .waitingForHelper, isOn: false, windowOpen: false) == .open)
        #expect(rule.update(step: nil, isOn: false, windowOpen: true) == .none)
    }

    /// The user closed it while the Turn On ran: it is not pushed back at them in the same Turn On.
    @Test func aWindowTheUserClosedStaysClosed() {
        var rule = TurnOnProgressWindow()
        #expect(rule.update(step: .settingUpHelper, isOn: false, windowOpen: false) == .open)
        #expect(rule.update(step: .waitingForHelper, isOn: false, windowOpen: false) == .none)
        #expect(rule.update(step: .settingUpHelper, isOn: false, windowOpen: false) == .none)
        #expect(rule.update(step: nil, isOn: true, windowOpen: false) == .none)
        // The next Turn On may show it again.
        #expect(rule.update(step: .settingUpHelper, isOn: false, windowOpen: false) == .open)
    }

    /// The user had the assistant open already: it is theirs, so success does not close it.
    @Test func aWindowTheUserOpenedIsNotClosed() {
        var rule = TurnOnProgressWindow()
        #expect(rule.update(step: .settingUpHelper, isOn: false, windowOpen: true) == .none)
        #expect(rule.update(step: nil, isOn: true, windowOpen: true) == .none)
    }
}
