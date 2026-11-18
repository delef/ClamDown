import ClamDownShared
import Foundation
import Testing
@testable import ClamDownAppKit

/// Fan control Always: the fans follow the curve while ClamDown is off too, through a fan-only session in the helper.
@MainActor @Suite struct ClamDownControllerIdleCoolingTests {
    private static var always: Settings {
        var settings = Settings()
        settings.fanControl = .always
        return settings
    }

    @Test func alwaysDrivesTheFansWhileOff() async {
        let rig = Rig(settings: Self.always)
        await rig.controller.start()
        #expect(rig.helper.fanPolicyCalls == [Self.always.fanPolicy])
        #expect(rig.helper.fanPolicyCalls.first?.onlyWhenLidClosed == false)
        #expect(rig.controller.state == .off)
        #expect(rig.helper.enableCalls.isEmpty)
    }

    @Test func withLidClosedLeavesTheFansAloneWhileOff() async {
        let rig = Rig()
        await rig.controller.start()
        #expect(rig.helper.fanPolicyCalls.isEmpty)
    }

    /// The helper ends a session the app stops sending, so the app sends it again every heartbeat interval.
    @Test func theSessionIsSentAgainToKeepItAlive() async {
        let rig = Rig(settings: Self.always, heartbeatInterval: .seconds(30))
        await rig.controller.start()
        await rig.time.untilWaiting(.seconds(30))
        rig.time.fire(.seconds(30))
        await eventually { rig.helper.fanPolicyCalls.count == 2 }
        #expect(rig.helper.fanPolicyCalls == [Self.always.fanPolicy, Self.always.fanPolicy])
    }

    @Test func choosingAnotherModeHandsTheFansBack() async {
        let rig = Rig(settings: Self.always)
        await rig.controller.start()
        var settings = rig.controller.settings
        settings.fanControl = .lidClosed
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.fanPolicyCalls.last?.isOff == true)
        #expect(rig.helper.fanPolicyCalls.count == 2)
    }

    @Test func choosingAlwaysStartsTheSession() async {
        let rig = Rig()
        await rig.controller.start()
        await rig.controller.updateSettings(Self.always)
        #expect(rig.helper.fanPolicyCalls == [Self.always.fanPolicy])
    }

    /// The switch-off ends the mode's policy in the helper, so the session starts again at once.
    @Test func theSessionComesBackAfterTheModeSwitchesOff() async {
        let rig = Rig(settings: Self.always)
        await rig.controller.toggle()
        #expect(rig.helper.fanPolicyCalls == [Self.always.fanPolicy])
        await rig.controller.toggle()
        #expect(rig.controller.state == .off)
        await eventually { rig.helper.fanPolicyCalls.count == 2 }
        #expect(rig.helper.fanPolicyCalls.last == Self.always.fanPolicy)
    }

    /// Setting the helper up is Turn On's and the setup assistant's job.
    @Test func aHelperThatIsNotAllowedIsLeftAlone() async {
        let rig = Rig(availability: [.requiresApproval], settings: Self.always)
        await rig.controller.start()
        #expect(rig.helper.fanPolicyCalls.isEmpty)
        #expect(rig.registrar.registerCount == 0)
    }

    /// An older helper drives the fans only while the mode is on, so it is updated first, as Turn On does.
    @Test func aHelperFromAnotherBuildIsUpdatedFirst() async {
        let rig = Rig(settings: Self.always, helperFingerprint: "new", installedFingerprint: "old")
        await rig.controller.start()
        #expect(rig.installed.fingerprint == "new")
        #expect(rig.helper.fanPolicyCalls == [Self.always.fanPolicy])
    }

    @Test func aSleepingMacGetsItsFansBack() async {
        let rig = Rig(settings: Self.always)
        await rig.controller.start()
        rig.controller.systemWillSleep()
        await eventually { rig.helper.fanPolicyCalls.count == 2 }
        #expect(rig.helper.fanPolicyCalls.last?.isOff == true)
        rig.controller.systemDidWake()
        await eventually { rig.helper.fanPolicyCalls.count == 3 }
        #expect(rig.helper.fanPolicyCalls.last == Self.always.fanPolicy)
    }

    @Test func quittingHandsTheFansBack() async {
        let rig = Rig(settings: Self.always)
        await rig.controller.start()
        await rig.controller.shutdown()
        #expect(rig.helper.fanPolicyCalls.last?.isOff == true)
        await drainMainActor()
        #expect(rig.helper.fanPolicyCalls.count == 2)
    }

    /// A helper that does not take the session is asked again on the next round, without a notice.
    @Test func aRefusedSessionIsTriedAgainQuietly() async {
        let rig = Rig(settings: Self.always, heartbeatInterval: .seconds(30))
        rig.helper.with { $0.fanPolicyError = HelperClientError.helper("The mode is not on") }
        await rig.controller.start()
        #expect(rig.controller.notice == nil)
        rig.helper.with { $0.fanPolicyError = nil }
        await rig.time.untilWaiting(.seconds(30))
        rig.time.fire(.seconds(30))
        await eventually { rig.helper.fanPolicyCalls.count == 2 }
        #expect(rig.helper.fanPolicyCalls.last == Self.always.fanPolicy)
    }
}
