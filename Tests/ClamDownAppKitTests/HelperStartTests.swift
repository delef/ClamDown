import Foundation
import Testing
@testable import ClamDownAppKit

/// macOS can register a helper and then not start it. Seen on a real Mac: the helper is killed at launch
/// ("Launch Constraint Violation"), and about ten seconds later macOS asks the user to allow it again.
/// Until then the registration still reads "allowed" and every request to the helper fails.
@MainActor @Suite struct HelperStartTests {
    private static let noAnswer = HelperClientError.connection("The helper did not answer.")

    /// The user pressed Turn On once. They are led to the approval, not left with "the helper did not answer".
    @Test func helperThatMacOSWillNotStartLeadsToApproval() async {
        let rig = Rig(availability: [.ready, .ready, .requiresApproval])
        var approvalRequests = 0
        rig.controller.onHelperNeedsApproval = { approvalRequests += 1 }
        rig.helper.with { $0.enableError = Self.noAnswer }

        await rig.controller.toggle()

        #expect(rig.controller.state == .needsApproval)
        #expect(approvalRequests == 1)
        #expect(rig.pauser.waits == [.seconds(2), .seconds(2)])
        #expect(rig.controller.helperAvailability == .requiresApproval)
    }

    @Test func turnOnGoesThroughOnceTheUserHasAllowedTheHelper() async {
        let rig = Rig(availability: [.ready, .requiresApproval])
        rig.helper.with { $0.enableError = Self.noAnswer }
        await rig.controller.turnOn(for: .seconds(7200))
        #expect(rig.controller.state == .needsApproval)

        rig.registrar.nowAnswers(.ready)
        rig.helper.with { $0.enableError = nil }
        await rig.controller.resumeTurnOn()

        #expect(rig.controller.state == .on)
        #expect(rig.controller.offAt != nil)
    }

    /// A helper that macOS starts a few seconds late is simply waited for.
    @Test func helperThatStartsLateIsWaitedFor() async {
        let rig = Rig()
        rig.helper.with { $0.enableError = Self.noAnswer }
        var notices: [String?] = []
        rig.pauser.whilePaused = { [controller = rig.controller, helper = rig.helper, pauser = rig.pauser] _ in
            notices.append(controller.notice)
            if pauser.waits.count == 2 { helper.with { $0.enableError = nil } }
        }

        await rig.controller.toggle()

        #expect(rig.controller.state == .on)
        #expect(rig.pauser.waits == [.seconds(2), .seconds(2)])
        #expect(notices == ["Waiting for the helper to start…", "Waiting for the helper to start…"])
        #expect(rig.controller.notice == nil)
    }

    @Test func helperThatNeverAnswersIsReportedAfterTheWait() async {
        let rig = Rig()
        rig.helper.with { $0.enableError = Self.noAnswer }

        await rig.controller.toggle()

        #expect(rig.controller.state == .failed("The helper did not answer."))
        #expect(rig.pauser.waits.count == 8)
        #expect(rig.controller.notice == nil)
    }

    /// The helper answered, with a failure of its own. Waiting would change nothing.
    @Test func failureTheHelperReportsIsNotWaitedOn() async {
        let rig = Rig()
        rig.helper.with { $0.enableError = HelperClientError.helper("pmset failed") }

        await rig.controller.toggle()

        #expect(rig.controller.state == .failed("pmset failed"))
        #expect(rig.pauser.waits.isEmpty)
    }

    @Test func helperTakenAwayWhileWaitingIsReportedAsSuch() async {
        let rig = Rig(availability: [.ready, .notRegistered])
        rig.helper.with { $0.enableError = Self.noAnswer }

        await rig.controller.toggle()

        #expect(rig.controller.state == .failed("The helper could not be registered."))
        #expect(rig.pauser.waits == [.seconds(2)])
    }
}
