import Foundation
import Testing
import ClamDownShared
@testable import ClamDownHelperKit

@Suite struct FanCurveTests {
    private let fan = FanReading(rpm: 0, minimum: 1000, maximum: 5000)
    private let curve = FanPolicy(mode: .curve, startTemperature: 60, fullSpeedTemperature: 80, onlyWhenLidClosed: false)

    @Test func curveRunsFromMinimumToMaximum() {
        #expect(FanCurve.speed(at: 40, policy: curve, fan: fan) == 1000)
        #expect(FanCurve.speed(at: 60, policy: curve, fan: fan) == 1000)
        #expect(FanCurve.speed(at: 70, policy: curve, fan: fan) == 3000)
        #expect(FanCurve.speed(at: 80, policy: curve, fan: fan) == 5000)
        #expect(FanCurve.speed(at: 110, policy: curve, fan: fan) == 5000)
    }

    @Test func fullSpeedIgnoresTemperature() {
        var policy = curve
        policy.mode = .fullSpeed
        #expect(FanCurve.speed(at: 30, policy: policy, fan: fan) == 5000)
    }

    @Test func speedRisesAtOnceAndFallsSlowly() {
        #expect(FanCurve.smoothed(previous: 2000, wanted: 4000, maxDrop: 150) == 4000)
        #expect(FanCurve.smoothed(previous: 4000, wanted: 1000, maxDrop: 150) == 3850)
        #expect(FanCurve.smoothed(previous: 1100, wanted: 1000, maxDrop: 150) == 1000)
        #expect(FanCurve.smoothed(previous: nil, wanted: 1000, maxDrop: 150) == 1000)
    }
}

@Suite struct FanControlTests {
    private let curve = FanPolicy(mode: .curve, startTemperature: 60, fullSpeedTemperature: 80, onlyWhenLidClosed: true)

    private func make(fans: FakeFans = FakeFans(), saved: SavedState? = nil) -> (HelperCore, FakeFans, FakeStore) {
        let store = FakeStore(initial: saved)
        let core = HelperCore(runner: FakeRunner(), store: store, fans: fans, fanStepDown: 150)
        return (core, fans, store)
    }

    private func enabled(fans: FakeFans = FakeFans()) async throws -> (HelperCore, FakeFans, FakeStore) {
        let rig = make(fans: fans)
        try await rig.0.enable(lowPowerOnBattery: false)
        return rig
    }

    @Test func policyNeedsTheModeOn() async {
        let (core, fans, _) = make()
        await #expect(throws: HelperError.notEnabled) { try await core.setFanPolicy(curve) }
        #expect(fans.targets.isEmpty)
    }

    @Test func curveSetsSpeedAndRecordsTheTakeOverFirst() async throws {
        let (core, fans, store) = try await enabled()
        try await core.setFanPolicy(curve)
        #expect(fans.targets == [[3000]])
        #expect(store.saved?.fansManual == true)
        #expect(store.saved?.sleepDisabled == false)
        #expect(await core.coolingStatus().isControlling)
    }

    @Test func systemModeLeavesTheFansAlone() async throws {
        let (core, fans, _) = try await enabled()
        var policy = curve
        policy.mode = .system
        try await core.setFanPolicy(policy)
        await core.updateFans()
        #expect(fans.targets.isEmpty)
        #expect(fans.releaseCount == 0)
    }

    @Test func switchingToSystemModeHandsTheFansBack() async throws {
        let (core, fans, store) = try await enabled()
        try await core.setFanPolicy(curve)
        var policy = curve
        policy.mode = .system
        try await core.setFanPolicy(policy)
        #expect(!fans.isHeld)
        #expect(store.saved?.fansManual == nil)
        #expect(store.saved?.sleepDisabled == false)
    }

    @Test func openLidHandsTheFansBackWhenAskedTo() async throws {
        let (core, fans, _) = try await enabled()
        try await core.setFanPolicy(curve)
        fans.set(lidClosed: false)
        await core.updateFans()
        #expect(!fans.isHeld)
        #expect(fans.targets.count == 1)
        fans.set(lidClosed: true)
        await core.updateFans()
        #expect(fans.isHeld)
        #expect(fans.targets.count == 2)
    }

    @Test func openLidKeepsControlWhenNotLimitedToClosedLid() async throws {
        let (core, fans, _) = try await enabled(fans: FakeFans(lidClosed: false))
        var policy = curve
        policy.onlyWhenLidClosed = false
        try await core.setFanPolicy(policy)
        #expect(fans.targets == [[3000]])
    }

    @Test func unknownLidStateCountsAsOpen() async throws {
        let (core, fans, _) = try await enabled(fans: FakeFans(lidClosed: nil))
        try await core.setFanPolicy(curve)
        #expect(fans.targets.isEmpty)
    }

    @Test func speedFallsGraduallyAfterLoadDrops() async throws {
        let (core, fans, _) = try await enabled(fans: FakeFans(temperature: 80))
        try await core.setFanPolicy(curve)
        fans.set(temperature: 50)
        await core.updateFans()
        await core.updateFans()
        #expect(fans.targets == [[5000], [4850], [4700]])
    }

    @Test func lostTemperatureHandsTheFansBack() async throws {
        let (core, fans, _) = try await enabled()
        try await core.setFanPolicy(curve)
        fans.set(temperature: nil)
        await core.updateFans()
        #expect(!fans.isHeld)
        #expect(await core.coolingStatus().problem == "Cannot read the CPU temperature.")
    }

    @Test func failedTakeOverIsNotRetriedUntilANewPolicy() async throws {
        let fans = FakeFans()
        fans.failSet()
        let (core, _, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(curve)
        #expect(fans.releaseCount == 1)
        #expect(await core.coolingStatus().problem?.hasPrefix("Could not set the fan speed") == true)
        fans.failSet(false)
        await core.updateFans()
        #expect(fans.targets.isEmpty)
        try await core.setFanPolicy(curve)
        #expect(fans.targets == [[3000]])
    }

    @Test func unsupportedMacNeverTouchesTheFans() async throws {
        let (core, fans, _) = try await enabled(fans: FakeFans(supportsControl: false))
        try await core.setFanPolicy(curve)
        #expect(fans.targets.isEmpty)
        #expect(await core.coolingStatus().problem == FanHardwareError.unsupported.description)
    }

    @Test func disableHandsTheFansBackAndForgetsThePolicy() async throws {
        let (core, fans, store) = try await enabled()
        try await core.setFanPolicy(curve)
        try await core.disable()
        #expect(!fans.isHeld)
        #expect(store.saved == nil)
        try await core.enable(lowPowerOnBattery: false)
        await core.updateFans()
        #expect(fans.targets.count == 1)  // no policy until the app sends one again
    }

    @Test func failedReleaseDoesNotBlockSwitchOffAndIsRetried() async throws {
        let (core, fans, store) = try await enabled()
        try await core.setFanPolicy(curve)
        fans.failRelease()
        try await core.disable()
        #expect(await core.isEnabled == false)
        #expect(store.saved == SavedState(fansManual: true))
        fans.failRelease(false)
        await core.updateFans()
        #expect(!fans.isHeld)
        #expect(store.saved == nil)
    }

    @Test func watchdogHandsTheFansBack() async throws {
        let t0 = SuspendingClock.now
        let fans = FakeFans()
        let core = HelperCore(runner: FakeRunner(), store: FakeStore(), fans: fans, watchdogTimeout: .seconds(90))
        try await core.enable(lowPowerOnBattery: false, now: t0)
        try await core.setFanPolicy(curve)
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(91))))
        #expect(!fans.isHeld)
    }

    @Test func startUpHandsBackFansLeftByACrash() async throws {
        let (core, fans, store) = make(saved: SavedState(sleepDisabled: false, fansManual: true))
        try await core.recoverOnStart()
        #expect(fans.releaseCount == 1)
        #expect(store.saved == nil)
    }

    @Test func startUpLeavesFansAloneWhenClamDownDidNotHoldThem() async throws {
        let (core, fans, _) = make(saved: SavedState(sleepDisabled: false))
        try await core.recoverOnStart()
        #expect(fans.releaseCount == 0)
    }

    @Test func failedStartUpReleaseIsRetried() async throws {
        let fans = FakeFans()
        fans.failRelease()
        let (core, _, store) = make(fans: fans, saved: SavedState(fansManual: true))
        await #expect(throws: FakeFailure.self) { try await core.recoverOnStart() }
        #expect(store.saved?.fansManual == true)
        fans.failRelease(false)
        await core.updateFans()
        #expect(fans.releaseCount == 2)
    }

    @Test func oldStateFilesStillDecode() throws {
        let old = Data(#"{"batteryLowPowerMode":true,"sleepDisabled":false}"#.utf8)
        #expect(try JSONDecoder().decode(SavedState.self, from: old) == SavedState(batteryLowPowerMode: true, sleepDisabled: false))
    }
}
