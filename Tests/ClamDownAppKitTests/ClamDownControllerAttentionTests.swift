import Foundation
import Testing
@testable import ClamDownAppKit

@MainActor @Suite struct ClamDownControllerAttentionTests {
    @Test func attentionWhenHelperIsNotReady() {
        let waiting = Rig(availability: [.requiresApproval])
        waiting.controller.refreshHelperAvailability()
        #expect(waiting.controller.needsAttention)

        let ready = Rig()
        ready.controller.refreshHelperAvailability()
        #expect(!ready.controller.needsAttention)
    }

    @Test func attentionForFailedState() async {
        let rig = Rig()
        rig.helper.with { $0.enableError = HelperClientError.helper("pmset failed") }
        await rig.controller.toggle()
        #expect(rig.controller.state == .failed("pmset failed"))
        #expect(rig.controller.needsAttention)
    }

    /// Turn On already read the helper state, so the icons must not wait for the next refresh.
    @Test func attentionWhileApprovalIsPending() async {
        let rig = Rig(availability: [.requiresApproval])
        await rig.controller.toggle()
        #expect(rig.controller.helperAvailability == .requiresApproval)
        #expect(rig.controller.needsAttention)
    }

    @Test func noAttentionAfterAutomaticSwitchOff() async {
        let rig = Rig()
        await rig.controller.toggle()
        rig.monitor.current = SystemSnapshot(batteryPercent: 5, isOnBattery: true, thermal: .nominal)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(!rig.controller.needsAttention)
    }

    /// The approval is taken back in System Settings while ClamDown sits idle.
    @Test func revokedApprovalShowsAtNextRefresh() {
        let rig = Rig(availability: [.ready, .requiresApproval])
        rig.controller.refreshHelperAvailability()
        #expect(!rig.controller.needsAttention)
        rig.controller.refreshHelperAvailability()
        #expect(rig.controller.needsAttention)
    }

    @Test func lostHelperIsNamedWhenHeartbeatFails() async {
        let rig = Rig(availability: [.ready, .requiresApproval])
        await rig.controller.toggle()
        rig.helper.with { $0.heartbeatResult = .failure(HelperClientError.connection("gone")) }
        await rig.controller.sendHeartbeat()
        let text = "Turned off: macOS no longer allows the helper. Open Setup to allow it again."
        #expect(rig.controller.state == .off)
        #expect(rig.controller.notice == text)
        #expect(rig.notifier.posted.last?.body == text)
        #expect(rig.controller.needsAttention)
    }

    @Test func plainSentenceForDeniedHelperStart() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "old")
        rig.registrar.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        await rig.controller.toggle()
        #expect(rig.controller.state == .failed(
            "Could not update the helper: macOS did not allow the helper to start. Allow ClamDown in Login Items, then try again."))
    }

    @Test func plainSentenceForOtherServiceErrors() async {
        let rig = Rig(availability: [.notRegistered])
        rig.registrar.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 3)
        await rig.controller.toggle()
        #expect(rig.controller.state == .failed("macOS could not set up the helper (error 3)."))
    }

    @Test func otherErrorsUseLocalizedDescription() async {
        let rig = Rig(availability: [.notRegistered])
        rig.registrar.registerError = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Disk is full."])
        await rig.controller.toggle()
        #expect(rig.controller.state == .failed("Disk is full."))
    }

    @Test func syncLaunchAtLoginStoresSystemValue() async {
        var settings = Settings()
        settings.launchAtLogin = true
        let rig = Rig(settings: settings)
        await rig.controller.syncLaunchAtLogin(systemValue: false)
        #expect(rig.controller.settings.launchAtLogin == false)
        #expect(rig.store.saved.count == 1)
        await rig.controller.syncLaunchAtLogin(systemValue: false)
        #expect(rig.store.saved.count == 1)
    }
}

@Suite struct HelperRefreshPaceTests {
    /// The user is in System Settings allowing the helper: the menu must catch up within seconds, not half a minute.
    @Test func looksOftenWhileSomethingNeedsTheUser() {
        #expect(HelperRefreshPace.interval(needsAttention: true) == 2)
    }

    @Test func looksRarelyWhenAllIsWell() {
        #expect(HelperRefreshPace.interval(needsAttention: false) == 30)
    }
}
