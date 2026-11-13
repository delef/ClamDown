import Foundation
import Testing
@testable import ClamDownAppKit

@MainActor @Suite struct ClamDownControllerSetupTests {
    private func hourTimer() -> Settings {
        var settings = Settings()
        settings.autoOffTimer = .hour1
        return settings
    }

    @Test func prepareRegistersWhenNotRegistered() async {
        let rig = Rig(availability: [.notRegistered, .ready])
        #expect(await rig.controller.prepareHelper() == .ready)
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.controller.state == .off)
        #expect(rig.helper.enableCalls.isEmpty)
    }

    @Test func prepareReportsPendingApproval() async {
        let rig = Rig(availability: [.notRegistered, .requiresApproval])
        rig.registrar.registerError = HelperClientError.helper("Operation not permitted")
        #expect(await rig.controller.prepareHelper() == .needsApproval)
        #expect(rig.registrar.openApprovalCount == 0)
        #expect(rig.controller.state == .off)
    }

    @Test func prepareReportsFailure() async {
        let rig = Rig(availability: [.notRegistered])
        rig.registrar.registerError = HelperClientError.helper("boom")
        #expect(await rig.controller.prepareHelper() == .failed("boom"))
        #expect(rig.controller.state == .off)
    }

    @Test func prepareUpdatesHelperFromAnotherBuild() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "old")
        #expect(await rig.controller.prepareHelper() == .ready)
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.installed.fingerprint == "new")
    }

    /// The assistant must open on every attempt, also while the state already says "needs approval".
    @Test func turnOnNeedingApprovalSignalsEveryTime() async {
        let rig = Rig(availability: [.requiresApproval])
        var signals = 0
        rig.controller.onHelperNeedsApproval = { signals += 1 }
        await rig.controller.toggle()
        await rig.controller.toggle()
        #expect(signals == 2)
        #expect(rig.registrar.openApprovalCount == 0)
        #expect(rig.controller.state == .needsApproval)
    }

    @Test func turnOnRemembersRequestedDuration() async {
        let rig = Rig(availability: [.requiresApproval])
        await rig.controller.turnOn(for: .seconds(7200))
        #expect(rig.controller.pendingTurnOn == TurnOnRequest(duration: .seconds(7200)))
    }

    /// "Until Switched Off" was asked for, so the timer setting must not sneak a timer in.
    @Test func resumeUsesRememberedDurationOnce() async {
        let rig = Rig(availability: [.requiresApproval, .ready], settings: hourTimer())
        await rig.controller.turnOn(for: nil)
        await rig.controller.resumeTurnOn()
        #expect(rig.controller.state == .on)
        #expect(rig.controller.offAt == nil)
        #expect(rig.controller.pendingTurnOn == nil)
    }

    @Test func resumeWithoutRequestUsesTimerSetting() async {
        let rig = Rig(settings: hourTimer())
        await rig.controller.resumeTurnOn()
        #expect(rig.controller.state == .on)
        #expect(rig.controller.offAt == rig.clock.now.addingTimeInterval(3600))
    }

    @Test func droppedRequestFallsBackToTimerSetting() async {
        let rig = Rig(availability: [.requiresApproval, .ready], settings: hourTimer())
        await rig.controller.turnOn(for: nil)
        rig.controller.dropPendingTurnOn()
        await rig.controller.resumeTurnOn()
        #expect(rig.controller.state == .on)
        #expect(rig.controller.offAt == rig.clock.now.addingTimeInterval(3600))
    }
}
