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
        var steps: [TurnOnStep?] = []
        rig.pauser.whilePaused = { [controller = rig.controller, helper = rig.helper, pauser = rig.pauser] _ in
            steps.append(controller.turnOnStep)
            if pauser.waits.count == 2 { helper.with { $0.enableError = nil } }
        }

        await rig.controller.toggle()

        #expect(rig.controller.state == .on)
        #expect(rig.pauser.waits == [.seconds(2), .seconds(2)])
        #expect(steps == [.waitingForHelper, .waitingForHelper])
        #expect(rig.controller.turnOnStep == nil)
        #expect(rig.controller.notice == nil)
    }

    /// Seen on a real Mac: after the user allowed the helper again, macOS kept the old job, which could no longer
    /// start. The registration read "allowed" and the helper stayed silent until it was registered afresh.
    @Test func helperThatStaysSilentIsRegisteredAfreshOnce() async {
        let rig = Rig(helperFingerprint: "this build", installedFingerprint: "this build")
        rig.helper.with { $0.enableError = Self.noAnswer }
        rig.pauser.whilePaused = { [registrar = rig.registrar, helper = rig.helper] _ in
            if registrar.unregisterCount == 1 { helper.with { $0.enableError = nil } }
        }

        await rig.controller.toggle()

        #expect(rig.controller.state == .on)
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.registrar.registerCount == 1)
        // Two quick looks, then the pause macOS needs between removing and registering.
        #expect(rig.pauser.waits == [.seconds(2), .seconds(2), .seconds(1)])
    }

    /// The fresh registration is the one macOS refuses to start, and it asks for approval some seconds later.
    @Test func approvalAskedAfterTheFreshRegistrationIsFollowed() async {
        let rig = Rig(availability: [.ready, .ready, .ready, .ready, .ready, .requiresApproval])
        var approvalRequests = 0
        rig.controller.onHelperNeedsApproval = { approvalRequests += 1 }
        rig.helper.with { $0.enableError = Self.noAnswer }

        await rig.controller.toggle()

        #expect(rig.controller.state == .needsApproval)
        #expect(approvalRequests == 1)
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.pauser.waits == [.seconds(2), .seconds(2), .seconds(1), .seconds(2), .seconds(2)])
    }

    /// Seen on a real Mac: launchd fails to start the old job (its app was replaced) within milliseconds,
    /// so the helper is registered afresh at once instead of after two quick looks.
    @Test func anOldJobThatLaunchdCannotStartIsRegisteredAfreshAtOnce() async {
        let rig = Rig(helperFingerprint: "this build", installedFingerprint: "this build")
        rig.helper.with { $0.enableError = Self.noAnswer }
        rig.jobs.says(.spawnFailed(reason: "78: EX_CONFIG"))
        rig.pauser.whilePaused = { [registrar = rig.registrar, helper = rig.helper, jobs = rig.jobs] _ in
            if registrar.unregisterCount == 1 {
                jobs.says(.running)
                helper.with { $0.enableError = nil }
            }
        }

        await rig.controller.toggle()

        #expect(rig.controller.state == .on)
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.pauser.waits == [.seconds(1)])  // only the pause macOS needs between removing and registering
    }

    /// Seen on a real Mac: macOS refuses to start a helper this Turn On has just registered, for example while
    /// ClamDown is switched off in Login Items & Extensions, and SMAppService still reads "allowed". Waiting and
    /// registering again change nothing, so the user is sent to Login Items at once and the Turn On is remembered.
    @Test func aFreshRegistrationThatLaunchdRefusesAsksForLoginItemsAtOnce() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "old")
        var approvalRequests = 0
        rig.controller.onHelperNeedsApproval = { approvalRequests += 1 }
        rig.helper.with { $0.enableError = Self.noAnswer }
        rig.jobs.says(.spawnFailed(reason: "78: EX_CONFIG"))

        await rig.controller.turnOn(for: .seconds(7200))

        #expect(rig.controller.state == .needsApproval)
        #expect(rig.controller.launchdRefusesHelper)
        #expect(approvalRequests == 1)
        #expect(rig.controller.pendingTurnOn == TurnOnRequest(duration: .seconds(7200)))
        #expect(rig.registrar.unregisterCount == 1)  // the update's own replacement, nothing more
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.pauser.waits == [.seconds(1)])  // only the pause macOS needs between removing and registering
        #expect(rig.controller.turnOnStep == nil)
    }

    /// ClamDown switched off in Login Items: launchd refuses the old job and the fresh registration alike.
    /// One fresh registration is tried, because a stale job after an app update looks the same; then the user
    /// is sent to Login Items instead of being kept waiting.
    @Test func aLoginItemSwitchedOffIsNamedAfterOneFreshRegistration() async {
        let rig = Rig(helperFingerprint: "this build", installedFingerprint: "this build")
        rig.helper.with { $0.enableError = Self.noAnswer }
        rig.jobs.says(.spawnFailed(reason: "78: EX_CONFIG"))

        await rig.controller.toggle()

        #expect(rig.controller.state == .needsApproval)
        #expect(rig.controller.launchdRefusesHelper)
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.pauser.waits == [.seconds(1)])
    }

    /// SMAppService reads "allowed" all along, so a refresh does not end the wait while launchd still refuses.
    @Test func aRefusedHelperKeepsAskingUntilLaunchdStartsIt() async {
        let rig = Rig(helperFingerprint: "this build", installedFingerprint: "this build")
        rig.helper.with { $0.enableError = Self.noAnswer }
        rig.jobs.says(.spawnFailed(reason: "78: EX_CONFIG"))
        await rig.controller.toggle()

        await rig.controller.recheckRefusedHelper()
        #expect(rig.controller.state == .needsApproval)

        rig.jobs.says(.running)
        await rig.controller.recheckRefusedHelper()
        #expect(rig.controller.state == .off)
        #expect(!rig.controller.launchdRefusesHelper)
        #expect(rig.controller.pendingTurnOn != nil)  // the setup window finishes it
    }

    @Test func aHelperThatStartsClearsTheRefusal() async {
        let rig = Rig(helperFingerprint: "this build", installedFingerprint: "this build")
        rig.helper.with { $0.enableError = Self.noAnswer }
        rig.jobs.says(.spawnFailed(reason: "78: EX_CONFIG"))
        await rig.controller.toggle()

        rig.jobs.says(.running)
        rig.helper.with { $0.enableError = nil }
        await rig.controller.resumeTurnOn()

        #expect(rig.controller.state == .on)
        #expect(!rig.controller.launchdRefusesHelper)
    }

    /// A helper launchd refuses is reported from launchd's answer, without a request that would wait for it.
    @Test func whetherTheHelperRunsIsAskedOfLaunchdFirst() async {
        let rig = Rig()
        rig.jobs.says(.spawnFailed(reason: "78: EX_CONFIG"))
        rig.helper.with { $0.hangs = true }
        rig.controller.helperAnswerLimit = .seconds(600)

        #expect(await rig.controller.checkHelperRuns() == .startFailed)
    }

    /// Seen on a real Mac: a request to a helper that launchd keeps failing to start got no answer at all, and the
    /// setup assistant said "Starting the helper…" for good. A request now gives up after a limit.
    @Test func aRequestThatGetsNoAnswerGivesUp() async {
        let rig = Rig()
        rig.helper.with { $0.hangs = true }
        rig.controller.helperAnswerLimit = .milliseconds(20)

        #expect(await rig.controller.checkHelperRuns() == .silent)
    }

    @Test func aTurnOnWhoseRequestsGetNoAnswerEnds() async {
        let rig = Rig()
        rig.helper.with { $0.hangs = true }
        rig.controller.helperAnswerLimit = .milliseconds(20)

        await rig.controller.toggle()

        #expect(rig.controller.state == .failed("The helper did not answer."))
        #expect(rig.controller.turnOnStep == nil)
    }

    /// launchd already refuses the registered helper: no request is sent, the helper is registered afresh.
    @Test func aHelperLaunchdAlreadyRefusesIsNotAskedFirst() async {
        let rig = Rig(helperFingerprint: "this build", installedFingerprint: "this build")
        rig.helper.with { $0.hangs = true }
        rig.controller.helperAnswerLimit = .seconds(600)
        rig.jobs.says(.spawnFailed(reason: "78: EX_CONFIG"))
        rig.pauser.whilePaused = { [registrar = rig.registrar, helper = rig.helper, jobs = rig.jobs] _ in
            if registrar.unregisterCount == 1 {
                jobs.says(.running)
                helper.with { $0.hangs = false }
            }
        }

        await rig.controller.toggle()

        #expect(rig.controller.state == .on)
        #expect(rig.registrar.unregisterCount == 1)
    }

    @Test func helperThatNeverAnswersIsReportedAfterOneFreshRegistration() async {
        let rig = Rig()
        rig.helper.with { $0.enableError = Self.noAnswer }

        await rig.controller.toggle()

        #expect(rig.controller.state == .failed("The helper did not answer."))
        #expect(rig.registrar.unregisterCount == 1)
        // Two quick looks, the registration pause, eight looks.
        #expect(rig.pauser.waits.count == 11)
        #expect(rig.controller.notice == nil)
    }

    @Test func freshRegistrationThatFailsIsReported() async {
        let rig = Rig()
        rig.helper.with { $0.enableError = Self.noAnswer }
        rig.registrar.unregisterError = HelperClientError.helper("busy")

        await rig.controller.toggle()

        #expect(rig.controller.state == .failed("The helper did not answer, and registering it again failed: busy"))
    }

    /// The helper comes up and answers with a failure of its own: that is the answer.
    @Test func failureReportedWhileWaitingEndsTheWait() async {
        let rig = Rig()
        rig.helper.with { $0.enableError = Self.noAnswer }
        rig.pauser.whilePaused = { [helper = rig.helper] _ in
            helper.with { $0.enableError = HelperClientError.helper("pmset failed") }
        }

        await rig.controller.toggle()

        #expect(rig.controller.state == .failed("pmset failed"))
        #expect(rig.pauser.waits == [.seconds(2)])
        #expect(rig.registrar.unregisterCount == 0)
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
