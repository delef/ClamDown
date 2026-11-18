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

    // MARK: - A helper that answers late or not at all

    /// A send that timed out may still have reached the helper, so the sleep hands the fans back all the same.
    @Test func aSendThatTimedOutIsStillEndedBeforeSleep() async {
        let rig = Rig(settings: Self.always)
        rig.controller.helperAnswerLimit = .milliseconds(20)
        rig.helper.with { $0.fanPolicyHangs = true }
        await rig.controller.start()
        rig.helper.with { $0.fanPolicyHangs = false }
        rig.controller.systemWillSleep()
        await eventually { rig.helper.fanPolicyCalls.count == 2 }
        #expect(rig.helper.fanPolicyCalls.last?.isOff == true)
    }

    @Test func aSendThatTimedOutIsStillEndedWhenLeavingAlways() async {
        let rig = Rig(settings: Self.always)
        rig.controller.helperAnswerLimit = .milliseconds(20)
        rig.helper.with { $0.fanPolicyHangs = true }
        await rig.controller.start()
        rig.helper.with { $0.fanPolicyHangs = false }
        var settings = rig.controller.settings
        settings.fanControl = .never
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.fanPolicyCalls.last?.isOff == true)
    }

    /// No round may take the fans between the hand-back before sleep and the wake.
    @Test func noSessionStartsWhileTheMacSleeps() async {
        let rig = Rig(settings: Self.always, heartbeatInterval: .seconds(30))
        await rig.controller.start()
        rig.controller.systemWillSleep()
        await eventually { rig.helper.fanPolicyCalls.count == 2 }
        await rig.time.untilWaiting(.seconds(30))
        rig.time.fire(.seconds(30))
        await drainMainActor()
        await rig.time.untilWaiting(.seconds(30))
        #expect(rig.helper.fanPolicyCalls.count == 2)
        rig.controller.systemDidWake()
        await eventually { rig.helper.fanPolicyCalls.count == 3 }
        #expect(rig.helper.fanPolicyCalls.last == Self.always.fanPolicy)
    }

    /// A curve changed while a send is on its way gets a round of its own, not one 30 seconds later.
    @Test func aSettingChangedDuringASendIsSentRightAfter() async {
        let rig = Rig(settings: Self.always)
        rig.controller.helperAnswerLimit = .milliseconds(50)
        rig.helper.with { $0.fanPolicyHangs = true }
        let started = Task { await rig.controller.start() }
        await eventually { rig.helper.fanPolicyCalls.count == 1 }
        rig.helper.with { $0.fanPolicyHangs = false }
        var settings = rig.controller.settings
        settings.fanStartTemperature = 55
        await rig.controller.updateSettings(settings)
        await started.value
        #expect(rig.helper.fanPolicyCalls.count == 2)
        #expect(rig.helper.fanPolicyCalls.last == settings.fanPolicy)
    }

    /// A helper launchd will not start never answers; the launch must not wait on it for ever.
    @Test func aSilentHelperDoesNotHoldUpTheLaunch() async {
        let rig = Rig(settings: Self.always)
        rig.controller.helperAnswerLimit = .milliseconds(20)
        rig.helper.with { $0.hangs = true }
        await rig.controller.start()
        #expect(rig.helper.fanPolicyCalls == [Self.always.fanPolicy])
    }

    // MARK: - Updating the helper in the background

    /// A Turn On pressed while the loop updates the helper runs after the update instead of being dropped.
    @Test func aTurnOnDuringTheBackgroundUpdateWaitsForIt() async {
        let rig = Rig(settings: Self.always, helperFingerprint: "new", installedFingerprint: "old")
        var turnOn: Task<Void, Never>?
        rig.pauser.yields = true
        rig.pauser.whilePaused = { _ in
            guard turnOn == nil else { return }
            turnOn = Task { @MainActor in await rig.controller.toggle() }
        }
        await rig.controller.start()
        await turnOn?.value
        #expect(turnOn != nil)
        #expect(rig.controller.state == .on)
        #expect(rig.installed.fingerprint == "new")
    }

    /// A failed update is not tried again every round; the next Turn On updates the helper anyway.
    @Test func aFailedBackgroundUpdateIsNotRepeatedEveryRound() async {
        let rig = Rig(settings: Self.always, helperFingerprint: "new", installedFingerprint: "old",
                      heartbeatInterval: .seconds(30))
        rig.registrar.unregisterError = HelperClientError.helper("busy")
        await rig.controller.start()
        let attempts = rig.registrar.unregisterCount
        #expect(attempts > 0)
        for _ in 0..<3 {
            await rig.time.untilWaiting(.seconds(30))
            rig.time.fire(.seconds(30))
            await drainMainActor()
        }
        #expect(rig.registrar.unregisterCount == attempts)
        #expect(rig.helper.fanPolicyCalls.isEmpty)
    }

    // MARK: - App Nap

    @Test func alwaysHoldsAnActivityWhileItRuns() async {
        let rig = Rig(settings: Self.always)
        await rig.controller.start()
        #expect(rig.coolingActivity.beginCount == 1 && rig.coolingActivity.endCount == 0)
        var settings = rig.controller.settings
        settings.fanControl = .lidClosed
        await rig.controller.updateSettings(settings)
        #expect(rig.coolingActivity.endCount == 1)
    }
}

/// The mode's own requests to the helper also have a time limit and a retry.
@MainActor @Suite struct ClamDownControllerHelperLimitTests {
    @Test func aHeartbeatWithoutAnAnswerEnds() async {
        let rig = Rig()
        rig.controller.heartbeatLimit = .milliseconds(20)
        await rig.controller.toggle()
        rig.helper.with { $0.heartbeatHangs = true }
        await rig.controller.sendHeartbeat()
        #expect(rig.controller.state == .off)
    }

    @Test func aSwitchOffWithoutAnAnswerKeepsTheSwitchOnAndSaysSo() async {
        let rig = Rig()
        rig.controller.switchOffLimit = .milliseconds(20)
        await rig.controller.toggle()
        rig.helper.with { $0.disableHangs = true }
        await rig.controller.toggle()
        #expect(rig.controller.state == .on)
        #expect(rig.controller.notice == "Could not turn off: The helper did not answer.")
    }

    /// A fan policy that did not get through at Turn On is sent again with the next heartbeat.
    @Test func aFanPolicyThatFailedIsSentAgainWithTheHeartbeat() async {
        let rig = Rig()
        rig.helper.with { $0.fanPolicyError = HelperClientError.helper("no SMC") }
        await rig.controller.toggle()
        #expect(rig.controller.notice == "Could not control the fans: no SMC")
        rig.helper.with { $0.fanPolicyError = nil }
        await rig.controller.sendHeartbeat()
        #expect(rig.helper.fanPolicyCalls.count == 2)
        #expect(rig.controller.notice == nil)
        await rig.controller.sendHeartbeat()
        #expect(rig.helper.fanPolicyCalls.count == 2)
    }
}
