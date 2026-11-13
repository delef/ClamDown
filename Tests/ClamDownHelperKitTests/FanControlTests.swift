import Foundation
import Testing
import ClamDownSensors
import ClamDownShared
@testable import ClamDownHelperKit

@Suite struct FanCurveTests {
    private let fan = FanReading(rpm: 0, minimum: 1000, maximum: 5000)
    private let curve = FanPolicy(points: [.init(temperature: 60, speed: 0), .init(temperature: 80, speed: 100)],
                                  onlyWhenLidClosed: false)

    @Test func curveRunsFromMinimumToMaximum() {
        #expect(FanCurve.speed(at: 40, policy: curve, fan: fan) == 1000)
        #expect(FanCurve.speed(at: 60, policy: curve, fan: fan) == 1000)
        #expect(FanCurve.speed(at: 70, policy: curve, fan: fan) == 3000)
        #expect(FanCurve.speed(at: 80, policy: curve, fan: fan) == 5000)
        #expect(FanCurve.speed(at: 110, policy: curve, fan: fan) == 5000)
    }

    @Test func pointsAtFullSpeedIgnoreTemperature() {
        let policy = FanPolicy(points: [.init(temperature: 40, speed: 100), .init(temperature: 80, speed: 100)],
                               onlyWhenLidClosed: false)
        #expect(FanCurve.speed(at: 30, policy: policy, fan: fan) == 5000)
    }

    @Test func safetyFloorRaisesALowCurve() {
        let quiet = FanPolicy(points: [.init(temperature: 40, speed: 0)], onlyWhenLidClosed: false)
        #expect(FanCurve.speed(at: 60, policy: quiet, fan: fan) == 1000)
        #expect(FanCurve.speed(at: 82.5, policy: quiet, fan: fan) == 3000)
        #expect(FanCurve.speed(at: 99, policy: quiet, fan: fan) == 5000)
    }

    @Test func speedRisesAtOnceAndFallsSlowly() {
        #expect(FanCurve.smoothed(previous: 2000, wanted: 4000, maxDrop: 150) == 4000)
        #expect(FanCurve.smoothed(previous: 4000, wanted: 1000, maxDrop: 150) == 3850)
        #expect(FanCurve.smoothed(previous: 1100, wanted: 1000, maxDrop: 150) == 1000)
        #expect(FanCurve.smoothed(previous: nil, wanted: 1000, maxDrop: 150) == 1000)
    }
}

@Suite struct FanControlTests {
    private let curve = FanPolicy(points: [.init(temperature: 60, speed: 0), .init(temperature: 80, speed: 100)],
                                  onlyWhenLidClosed: true)

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

    @Test func policyWithoutPointsLeavesTheFansAlone() async throws {
        let (core, fans, _) = try await enabled()
        var policy = curve
        policy.points = []
        try await core.setFanPolicy(policy)
        await core.updateFans()
        #expect(fans.targets.isEmpty)
        #expect(fans.releaseCount == 0)
    }

    @Test func switchingFanControlOffHandsTheFansBack() async throws {
        let (core, fans, store) = try await enabled()
        try await core.setFanPolicy(curve)
        var policy = curve
        policy.points = []
        try await core.setFanPolicy(policy)
        #expect(!fans.isHeld)
        #expect(store.saved?.fansManual == nil)
        #expect(store.saved?.sleepDisabled == false)
    }

    @Test func theHelperRepairsThePolicyItIsSent() async throws {
        let (core, fans, _) = try await enabled()
        // Out of order: the second point is raised to the first, so the curve is full speed everywhere.
        try await core.setFanPolicy(FanPolicy(points: [.init(temperature: 80, speed: 100), .init(temperature: 60, speed: 0)],
                                              onlyWhenLidClosed: true))
        #expect(fans.targets == [[5000]])
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

/// Which speed the helper asks for: the curve on the average CPU temperature with the safety floor,
/// or full speed while a core or the whole Mac is too hot.
@Suite struct FanSpeedRuleTests {
    private let t0 = SuspendingClock.now
    private let standard = FanPolicy(points: StandardCurve.points(start: 50, full: 75), onlyWhenLidClosed: true)
    private let middle = FanPolicy(points: [.init(temperature: 60, speed: 0), .init(temperature: 80, speed: 100)],
                                   onlyWhenLidClosed: true)

    private func at(_ seconds: Int) -> SuspendingClock.Instant { t0.advanced(by: .seconds(seconds)) }

    private func enabled(fans: FakeFans = FakeFans(), thermal: FakeThermal? = nil) async throws -> (HelperCore, FakeFans) {
        let core = HelperCore(runner: FakeRunner(), store: FakeStore(), fans: fans, thermal: thermal, fanStepDown: 150)
        try await core.enable(lowPowerOnBattery: false, now: t0)
        return (core, fans)
    }

    @Test func speedFromPercentSpansTheFansRange() {
        let fan = FanReading(rpm: 0, minimum: 1000, maximum: 5000)
        #expect(FanCurve.speed(percent: 0, fan: fan) == 1000)
        #expect(FanCurve.speed(percent: 50, fan: fan) == 3000)
        #expect(FanCurve.speed(percent: 100, fan: fan) == 5000)
    }

    @Test func curveFollowsTheAverage() async throws {
        let fans = FakeFans(temperature: 62.5)
        fans.set(hottest: 90)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(standard, now: at(0))
        #expect(fans.targets == [[3000]])  // min + 50 % of the range
        let status = await core.coolingStatus()
        #expect(status.override == nil)
        #expect(status.hottestCPUTemperature == 90)
        #expect(status.control == .controlling)
    }

    @Test func floorAppliesInTheHelper() async throws {
        let fans = FakeFans(temperature: 90)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(FanPolicy(points: [.init(temperature: 40, speed: 0)], onlyWhenLidClosed: true), now: at(0))
        #expect(fans.targets == [[4200]])  // 80 % of the range
    }

    @Test func hotCoreRunsFullSpeed() async throws {
        let fans = FakeFans(temperature: 70)
        fans.set(hottest: 100)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(middle, now: at(0))
        for tick in 1...3 { await core.updateFans(now: at(3 * tick)) }
        #expect(fans.targets.last == [3000])
        #expect(await core.coolingStatus().override == nil)
        await core.updateFans(now: at(12))
        #expect(fans.targets.last == [5000])
        #expect(await core.coolingStatus().override == .hotCore)
    }

    @Test func hotCoreOverrideEndsAndTheSpeedFallsGradually() async throws {
        let fans = FakeFans(temperature: 70)
        fans.set(hottest: 100)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(middle, now: at(0))
        await core.updateFans(now: at(12))
        #expect(fans.targets.last == [5000])
        fans.set(hottest: 90)
        await core.updateFans(now: at(15))
        await core.updateFans(now: at(42))
        #expect(fans.targets.last == [5000])
        await core.updateFans(now: at(45))
        #expect(fans.targets.last == [4850])
        #expect(await core.coolingStatus().override == nil)
    }

    @Test func missingHottestKeepsTheCurveAndShowsNoHottest() async throws {
        let fans = FakeFans(temperature: 70)
        fans.set(hottest: nil)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(middle, now: at(0))
        for tick in 1...20 { await core.updateFans(now: at(3 * tick)) }
        #expect(Set(fans.targets) == [[3000]])
        let status = await core.coolingStatus()
        #expect(status.override == nil)
        #expect(status.hottestCPUTemperature == nil)
        #expect(status.cpuTemperature == 70)
    }

    @Test func seriousSystemLevelRunsFullSpeed() async throws {
        let thermal = FakeThermal(.serious)
        let (core, fans) = try await enabled(thermal: thermal)
        try await core.setFanPolicy(middle, now: at(0))
        #expect(fans.targets == [[5000]])
        #expect(await core.coolingStatus().override == .system)
        thermal.level = .critical
        await core.updateFans(now: at(3))
        #expect(fans.targets.last == [5000])
        thermal.level = .nominal
        await core.updateFans(now: at(6))
        #expect(fans.targets.last == [4850])
        #expect(await core.coolingStatus().override == nil)
    }

    @Test func fairLevelDoesNot() async throws {
        let (core, fans) = try await enabled(thermal: FakeThermal(.fair))
        try await core.setFanPolicy(middle, now: at(0))
        #expect(fans.targets == [[3000]])
        #expect(await core.coolingStatus().override == nil)
    }

    @Test func statusReportsTheHelpersOwnThermalLevel() async throws {
        let (core, _) = try await enabled(thermal: FakeThermal(.fair))
        #expect(await core.coolingStatus().systemThermalLevel == .fair)
        let (bare, _) = try await enabled()
        #expect(await bare.coolingStatus().systemThermalLevel == nil)
    }

    @Test func overridesStillRespectTheOpenLid() async throws {
        let fans = FakeFans(temperature: 70, lidClosed: false)
        let (core, _) = try await enabled(fans: fans, thermal: FakeThermal(.critical))
        try await core.setFanPolicy(middle, now: at(0))
        #expect(fans.targets.isEmpty)
        let status = await core.coolingStatus()
        #expect(status.control == .idle)
        #expect(status.override == nil)
    }

    @Test func statusIsIdleWithoutAPolicy() async throws {
        let (core, _) = try await enabled()
        #expect(await core.coolingStatus().control == .idle)
    }

    @Test func statusDoesNotChangeControl() async throws {
        let fans = FakeFans(temperature: 70)
        fans.set(hottest: 100)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(middle, now: at(0))
        for _ in 0..<10 { _ = await core.coolingStatus() }
        #expect(fans.targets == [[3000]])
        #expect(fans.releaseCount == 0)
    }
}
