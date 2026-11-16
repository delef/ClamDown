import ClamDownShared
import Testing
@testable import ClamDownAppKit

@Suite struct FanAlertTests {
    static let reason = "Fan 2 does not reach the speed it was set to."
    static let line = "ClamDown is not controlling the fans. macOS has them. Fan 2 does not reach the speed it was set to."

    static func status(_ control: FanControlState, holding: Bool = false, reason: String? = reason,
                       handBackFailed: Bool = false) -> CoolingStatus {
        CoolingStatus(cpuTemperature: 70, fans: [], isControlling: holding,
                      problem: control == .retrying || control == .stopped ? reason : nil, control: control,
                      handBackFailed: handBackFailed)
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
            == .show(line: "ClamDown is not controlling the fans. macOS has them. Cannot open the SMC.", notify: false))
    }

    @Test func resetClearsAShownLineAndStartsAfresh() {
        var alert = FanAlert()
        #expect(alert.reset() == .none)
        _ = alert.update(Self.status(.stopped))
        #expect(alert.reset() == .clear)
        #expect(alert.update(Self.status(.stopped)) == .show(line: Self.line, notify: true))
    }

    // MARK: - The helper's own reasons in the line

    static let stopped = "ClamDown is not controlling the fans. macOS has them."

    @Test(arguments: [
        "Could not set the fan speed: macOS did not hand over fan 1.",
        "Could not read the sensors: SMC call for F0Tg failed (kern 5, result 132).",
        "Cannot read the temperature sensors.",
        "SMC key F0Md does not exist.",
        "macOS did not hand over fan 2.",
    ])
    func theHelpersReasonFollowsAsItsOwnSentence(reason: String) {
        #expect(FanAlert.line(reason: reason) == "\(Self.stopped) \(reason)")
    }

    @Test func aReasonWithoutAFullStopGetsOne() {
        #expect(FanAlert.line(reason: "Could not set the fan speed: Expected targets for 2 fans, got 1")
            == "\(Self.stopped) Could not set the fan speed: Expected targets for 2 fans, got 1.")
    }

    @Test func neverTwoFullStops() {
        for reason in ["Fan 1 stalled...", "Fan 1 stalled\u{2026}", "Fan 1 stalled. "] {
            #expect(FanAlert.line(reason: reason) == "\(Self.stopped) Fan 1 stalled.")
        }
    }

    @Test func rawErrorTextOnSeveralLinesReadsAsOne() {
        #expect(FanAlert.line(reason: "Could not set the fan speed:\n  kern 5\tresult 132\n")
            == "\(Self.stopped) Could not set the fan speed: kern 5 result 132.")
    }

    /// The hand-back failed: the helper still holds the fans and runs them at full speed, so macOS does not have them.
    @Test func aFailedHandBackSaysTheFansRunAtFullSpeed() {
        var alert = FanAlert()
        let reason = "Could not hand the fans back to macOS: SMC call for Ftst failed."
        let line = "ClamDown is not controlling the fans. The fans run at full speed. \(reason)"
        #expect(alert.update(Self.status(.stopped, holding: true, reason: reason, handBackFailed: true))
            == .show(line: line, notify: true))
        #expect(FanAlert.line(reason: nil, fansAtFullSpeed: true)
            == "ClamDown is not controlling the fans. The fans run at full speed.")
    }

    @Test func noReasonLeavesItOut() {
        #expect(FanAlert.line(reason: nil) == "ClamDown is not controlling the fans. macOS has them.")
        #expect(FanAlert.line(reason: " . ") == "ClamDown is not controlling the fans. macOS has them.")
    }
}
