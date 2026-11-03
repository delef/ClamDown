import Testing
@testable import WakeupAppKit

@Suite struct MenuPresentationTests {
    @Test func offState() {
        #expect(MenuPresentation(state: .off, notice: nil)
            == MenuPresentation(symbolName: "cup.and.saucer", toggleTitle: "Turn On", statusLine: nil))
    }

    @Test func onState() {
        let p = MenuPresentation(state: .on, notice: nil)
        #expect(p.symbolName == "cup.and.saucer.fill" && p.toggleTitle == "Turn Off" && p.statusLine == nil)
    }

    @Test func approvalState() {
        let p = MenuPresentation(state: .needsApproval, notice: nil)
        #expect(p.statusLine == "Approve Wakeup in System Settings > Login Items")
        #expect(p.symbolName == "cup.and.saucer" && p.toggleTitle == "Turn On")
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
