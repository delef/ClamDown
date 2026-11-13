import Testing
@testable import ClamDownAppKit

@MainActor @Suite struct ClamDownControllerHelperTests {
    @Test func turningOnReinstallsHelperFromAnotherBuild() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "old")
        await rig.controller.toggle()
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.installed.fingerprint == "new")
        #expect(rig.controller.state == .on)
    }

    /// macOS refuses a registration that follows a removal at once, and then leaves no helper registered.
    @Test func updatePausesBetweenRemovingAndRegistering() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "old")
        await rig.controller.toggle()
        #expect(rig.registrar.pauses == [.seconds(1)])
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.controller.state == .on)
        #expect(rig.helper.enableCalls == [true])
    }

    /// A refused registration makes macOS wait all over again, so the next attempt comes after a longer pause.
    @Test func updateTriesAgainAfterALongerPauseWhenRefused() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "old")
        rig.registrar.pausesARemovalCosts = 2
        await rig.controller.toggle()
        #expect(rig.registrar.pauses == [.seconds(1), .seconds(2)])
        #expect(rig.registrar.registerCount == 2)
        #expect(rig.controller.state == .on)
        #expect(rig.installed.fingerprint == "new")
    }

    @Test func updateGivesUpAfterThreeRefusals() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "old")
        rig.registrar.pausesARemovalCosts = 10
        await rig.controller.toggle()
        #expect(rig.registrar.pauses == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(rig.registrar.registerCount == 3)
        #expect(rig.controller.state == .failed("Could not update the helper: Operation not permitted"))
        #expect(rig.helper.enableCalls.isEmpty)
        #expect(rig.installed.fingerprint == "old")
    }

    @Test func approvalAskedDuringAnUpdateEndsTheAttempts() async {
        let rig = Rig(availability: [.ready, .requiresApproval], helperFingerprint: "new", installedFingerprint: "old")
        rig.registrar.pausesARemovalCosts = 10
        await rig.controller.toggle()
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.controller.state == .needsApproval)
    }

    @Test func turningOnKeepsHelperWhenBuildIsUnchanged() async {
        let rig = Rig(helperFingerprint: "same", installedFingerprint: "same")
        await rig.controller.toggle()
        #expect(rig.registrar.unregisterCount == 0)
        #expect(rig.registrar.registerCount == 0)
        #expect(rig.controller.state == .on)
    }

    @Test func updateNeedingApprovalStaysOffAndRecordsNewBuild() async {
        let rig = Rig(availability: [.ready, .requiresApproval], helperFingerprint: "new", installedFingerprint: "old")
        await rig.controller.toggle()
        #expect(rig.controller.state == .needsApproval)
        #expect(rig.helper.enableCalls.isEmpty)
        #expect(rig.registrar.openApprovalCount == 0)
        // The registered helper is already this build, so approving it must not trigger another reinstall.
        #expect(rig.installed.fingerprint == "new")
    }

    @Test func approvingFirstRegistrationDoesNotReinstallOnNextTurnOn() async {
        let rig = Rig(availability: [.notRegistered, .requiresApproval, .ready], helperFingerprint: "new", installedFingerprint: nil)
        await rig.controller.toggle()
        #expect(rig.controller.state == .needsApproval)
        #expect(rig.installed.fingerprint == "new")
        await rig.controller.toggle()
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.registrar.unregisterCount == 0)
        #expect(rig.controller.state == .on)
    }

    @Test func failedUpdateStaysOffAndReports() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "old")
        rig.registrar.unregisterError = HelperClientError.helper("locked")
        await rig.controller.toggle()
        #expect(rig.controller.state == .failed("Could not update the helper: locked"))
        #expect(rig.helper.enableCalls.isEmpty)
        #expect(rig.installed.fingerprint == "old")
    }

    @Test func reinstallTurnsOffFirstAndRecordsNewBuild() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "new")
        await rig.controller.toggle()
        await rig.controller.reinstallHelper()
        #expect(rig.helper.disableCount == 1)
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.controller.state == .off)
        #expect(rig.controller.notice == "Helper reinstalled.")
        #expect(rig.installed.fingerprint == "new")
        #expect(rig.registrar.pauses == [.seconds(1)])
    }

    @Test func reinstallFailureShowsStatus() async {
        let rig = Rig()
        rig.registrar.unregisterError = HelperClientError.helper("busy")
        await rig.controller.reinstallHelper()
        #expect(rig.controller.state == .failed("Could not reinstall the helper: busy"))
    }

    @Test func removeHelperUnregistersAndForgetsBuild() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "new")
        await rig.controller.removeHelper()
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.registrar.registerCount == 0)
        #expect(rig.installed.fingerprint == nil)
        #expect(rig.controller.state == .off)
        #expect(rig.controller.notice == "Helper removed. Turn On sets it up again.")
    }

    @Test func removeHelperWhileOnTurnsOffFirst() async {
        let rig = Rig()
        await rig.controller.toggle()
        await rig.controller.removeHelper()
        #expect(rig.helper.disableCount == 1)
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.controller.state == .off)
    }
}
