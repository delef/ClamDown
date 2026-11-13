import ClamDownShared
import Testing
@testable import ClamDownAppKit

@Suite struct FanAlertTests {
    static let reason = "Fan 2 does not reach the speed it was set to."
    static let line = "ClamDown is not controlling the fans: fan 2 does not reach the speed it was set to. macOS has them."

    static func status(_ control: FanControlState, holding: Bool = false, reason: String? = reason) -> CoolingStatus {
        CoolingStatus(cpuTemperature: 70, fans: [], isControlling: holding,
                      problem: control == .retrying || control == .stopped ? reason : nil, control: control)
    }

    @Test func stopShowsALineAndNotifiesOnce() {
        var alert = FanAlert()
        #expect(alert.update(Self.status(.controlling, holding: true)) == .none)
        #expect(alert.update(Self.status(.stopped)) == .show(line: Self.line, notify: true))
        #expect(alert.update(Self.status(.stopped)) == .none)
        #expect(alert.update(Self.status(.stopped)) == .none)
    }

    @Test func retryShowsNothing() {
        var alert = FanAlert()
        #expect(alert.update(Self.status(.retrying)) == .none)
        #expect(alert.update(Self.status(.retrying)) == .none)
    }

    /// Only With Lid Closed and an open lid: the helper is idle, which is not a fault.
    @Test func openLidShowsNothing() {
        var alert = FanAlert()
        #expect(alert.update(Self.status(.idle)) == .none)
    }

    @Test func controlBackClearsTheLine() {
        var alert = FanAlert()
        _ = alert.update(Self.status(.stopped))
        #expect(alert.update(Self.status(.controlling, holding: true)) == .clear)
        #expect(alert.update(Self.status(.controlling, holding: true)) == .none)
    }

    @Test func secondStopNotifiesAgain() {
        var alert = FanAlert()
        _ = alert.update(Self.status(.stopped))
        _ = alert.update(Self.status(.controlling, holding: true))
        #expect(alert.update(Self.status(.stopped)) == .show(line: Self.line, notify: true))
    }

    /// A stopped helper's slow retry holds the fans for a minute before it reports controlling again.
    /// It is still stopped: the line stays and nothing is posted again.
    @Test func aSlowRetryThatHoldsIsNotControlBack() {
        var alert = FanAlert()
        _ = alert.update(Self.status(.stopped))
        #expect(alert.update(Self.status(.stopped, holding: true)) == .none)
        #expect(alert.update(Self.status(.controlling, holding: true)) == .clear)
    }

    /// Stopped, then the lid opens with Only With Lid Closed: idle is not "control returned", so closing
    /// the lid on the same stop does not notify a second time.
    @Test func idleInTheMiddleOfAStopIsNotControlBack() {
        var alert = FanAlert()
        _ = alert.update(Self.status(.stopped))
        #expect(alert.update(Self.status(.idle)) == .none)
        #expect(alert.update(Self.status(.stopped)) == .none)
    }

    @Test func controllingWithoutHoldingTheFansIsNotControlBack() {
        var alert = FanAlert()
        _ = alert.update(Self.status(.stopped))
        #expect(alert.update(Self.status(.controlling, holding: false)) == .none)
        #expect(alert.update(Self.status(.stopped)) == .none)
    }

    @Test func retryingAfterAStopKeepsTheLine() {
        var alert = FanAlert()
        _ = alert.update(Self.status(.stopped))
        #expect(alert.update(Self.status(.retrying)) == .none)
    }

    @Test func noStatusChangesNothing() {
        var alert = FanAlert()
        _ = alert.update(Self.status(.stopped))
        #expect(alert.update(nil) == .none)
        #expect(alert.update(Self.status(.stopped)) == .none)
    }

    @Test func aNewReasonReplacesTheLineWithoutANotification() {
        var alert = FanAlert()
        _ = alert.update(Self.status(.stopped))
        #expect(alert.update(Self.status(.stopped, reason: "Cannot open the SMC."))
            == .show(line: "ClamDown is not controlling the fans: cannot open the SMC. macOS has them.", notify: false))
    }

    @Test func resetClearsAShownLineAndStartsAfresh() {
        var alert = FanAlert()
        #expect(alert.reset() == .none)
        _ = alert.update(Self.status(.stopped))
        #expect(alert.reset() == .clear)
        #expect(alert.update(Self.status(.stopped)) == .show(line: Self.line, notify: true))
    }

    // MARK: - The helper's own reasons in the line

    @Test(arguments: [
        ("Could not set the fan speed: macOS did not hand over fan 1.",
         "could not set the fan speed: macOS did not hand over fan 1"),
        ("Could not read the sensors: SMC call for F0Tg failed (kern 5, result 132)",
         "could not read the sensors: SMC call for F0Tg failed (kern 5, result 132)"),
        ("Could not set the fan speed: Expected targets for 2 fans, got 1.",
         "could not set the fan speed: Expected targets for 2 fans, got 1"),
        ("Cannot read the CPU temperature.", "cannot read the CPU temperature"),
        ("Could not read every fan.", "could not read every fan"),
        ("Could not hand the fans back to macOS: SMC key F0Md does not exist",
         "could not hand the fans back to macOS: SMC key F0Md does not exist"),
        ("Cannot open the SMC.", "cannot open the SMC"),
    ])
    func helperReasonsReadAsPartOfTheSentence(reason: String, expected: String) {
        #expect(FanAlert.line(reason: reason) == "ClamDown is not controlling the fans: \(expected). macOS has them.")
    }

    @Test func aReasonThatStartsWithANameKeepsItsCapital() {
        #expect(FanAlert.line(reason: "SMC key F0Md does not exist")
            == "ClamDown is not controlling the fans: SMC key F0Md does not exist. macOS has them.")
        #expect(FanAlert.line(reason: "ClamDown lost the helper.")
            == "ClamDown is not controlling the fans: ClamDown lost the helper. macOS has them.")
        #expect(FanAlert.line(reason: "Mac is too hot.")
            == "ClamDown is not controlling the fans: Mac is too hot. macOS has them.")
        #expect(FanAlert.line(reason: "macOS did not hand over fan 2.")
            == "ClamDown is not controlling the fans: macOS did not hand over fan 2. macOS has them.")
    }

    @Test func neverTwoFullStops() {
        #expect(FanAlert.line(reason: "Fan 1 stalled...") == "ClamDown is not controlling the fans: fan 1 stalled. macOS has them.")
        #expect(FanAlert.line(reason: "Fan 1 stalled…") == "ClamDown is not controlling the fans: fan 1 stalled. macOS has them.")
        #expect(FanAlert.line(reason: "Fan 1 stalled. ") == "ClamDown is not controlling the fans: fan 1 stalled. macOS has them.")
    }

    @Test func rawErrorTextOnSeveralLinesReadsAsOne() {
        #expect(FanAlert.line(reason: "Could not set the fan speed:\n  kern 5\tresult 132\n")
            == "ClamDown is not controlling the fans: could not set the fan speed: kern 5 result 132. macOS has them.")
    }

    @Test func noReasonLeavesItOut() {
        #expect(FanAlert.line(reason: nil) == "ClamDown is not controlling the fans. macOS has them.")
        #expect(FanAlert.line(reason: " . ") == "ClamDown is not controlling the fans. macOS has them.")
    }
}
