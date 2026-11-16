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
        let core = HelperCore(runner: FakeRunner(), store: store, originals: FakeOriginalStore(), fans: fans, fanStepDown: 150)
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
        // Three-second ticks: the fall is limited by time, so the ticks carry their instants.
        let t0 = SuspendingClock.now
        try await core.setFanPolicy(curve, now: t0)
        fans.set(temperature: 50)
        await core.updateFans(now: t0.advanced(by: .seconds(3)))
        await core.updateFans(now: t0.advanced(by: .seconds(6)))
        #expect(fans.targets == [[5000], [4850], [4700]])
    }

    @Test func lostTemperatureHandsTheFansBack() async throws {
        let (core, fans, _) = try await enabled()
        try await core.setFanPolicy(curve)
        fans.set(temperature: nil)
        await core.updateFans()
        #expect(!fans.isHeld)
        #expect(await core.coolingStatus().problem == "Cannot read the temperature sensors.")
    }

    /// The other groups run far cooler than the chip, so the curve must not fall back to them.
    @Test func losingTheCPUWhileOtherGroupsReadIsAFault() async throws {
        let (core, fans, _) = try await enabled()
        fans.set(group: .airflow, 40)
        try await core.setFanPolicy(curve)
        #expect(fans.isHeld)
        fans.set(temperature: nil)
        await core.updateFans()
        #expect(!fans.isHeld)
        #expect(await core.coolingStatus().problem == "Cannot read the CPU temperature.")
    }

    /// A failed pmset step keeps the mode on, so without the stop a tick before exit would take the fans again.
    @Test func afterShutdownTheFansAreNeverTakenAgain() async throws {
        let runner = FakeRunner()
        let fans = FakeFans()
        let core = HelperCore(runner: runner, store: FakeStore(), originals: FakeOriginalStore(), fans: fans)
        try await core.enable(lowPowerOnBattery: false)
        try await core.setFanPolicy(curve)
        runner.fail(.setSleepDisabled(false))
        await #expect(throws: FakeFailure.self) { try await core.shutdown() }
        #expect(!fans.isHeld)
        #expect(await core.isEnabled)
        await core.updateFans()
        #expect(!fans.isHeld)
        #expect(fans.targets.count == 1)
    }

    @Test func failedTakeOverHandsTheFansBackAndIsReported() async throws {
        let fans = FakeFans()
        fans.failSet()
        let (core, _, store) = try await enabled(fans: fans)
        try await core.setFanPolicy(curve)
        #expect(fans.releaseCount == 1)
        #expect(store.saved?.fansManual == nil)
        let status = await core.coolingStatus()
        #expect(status.problem?.hasPrefix("Could not set the fan speed") == true)
        #expect(status.control == .retrying)
        #expect(!status.isControlling)
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
        let core = HelperCore(runner: FakeRunner(), store: FakeStore(), originals: FakeOriginalStore(), fans: fans, watchdogTimeout: .seconds(90))
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
        fans.followsTargets = true
        let core = HelperCore(runner: FakeRunner(), store: FakeStore(), originals: FakeOriginalStore(), fans: fans, thermal: thermal, fanStepDown: 150)
        try await core.enable(lowPowerOnBattery: false, now: t0)
        return (core, fans)
    }

    private func at(milliseconds: Int) -> SuspendingClock.Instant { t0.advanced(by: .milliseconds(milliseconds)) }

    // MARK: - The fall is limited by time, not by call

    /// 150 rpm per 3 s is 5 rpm per 0.1 s, however often `updateFans` runs.
    @Test func callsATenthOfASecondApartFallAtMostFiveRpm() async throws {
        let fans = FakeFans(temperature: 80)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(middle, now: at(0))
        #expect(fans.targets.last == [5000])
        fans.set(temperature: 50)
        await core.updateFans(now: at(milliseconds: 100))
        #expect(fans.targets.last.map { 5000 - $0[0] } ?? 0 <= 5.000_001)
        await core.updateFans(now: at(milliseconds: 200))
        #expect(fans.targets.last.map { 5000 - $0[0] } ?? 0 <= 10.000_001)
    }

    @Test func callsThreeSecondsApartFallAtMost150Rpm() async throws {
        let fans = FakeFans(temperature: 80)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(middle, now: at(0))
        fans.set(temperature: 50)
        await core.updateFans(now: at(3))
        #expect(fans.targets.last == [4850])
        await core.updateFans(now: at(6))
        #expect(fans.targets.last == [4700])
    }

    @Test func manyCallsInThreeSecondsFallNoMoreThanOne() async throws {
        let fans = FakeFans(temperature: 80)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(middle, now: at(0))
        fans.set(temperature: 50)
        for step in 1...30 { await core.updateFans(now: at(milliseconds: step * 100)) }
        let last = try #require(fans.targets.last?.first)
        #expect(last >= 4850 - 0.001)
    }

    /// A new policy runs `updateFans` at once; a stream of them must not get around the limit.
    @Test func aNewLowerPolicyRightAfterAWriteDoesNotFallFaster() async throws {
        let fans = FakeFans(temperature: 70)
        let (core, _) = try await enabled(fans: fans)
        let high = FanPolicy(points: [.init(temperature: 40, speed: 100)], onlyWhenLidClosed: true)
        try await core.setFanPolicy(high, now: at(0))
        #expect(fans.targets.last == [5000])
        for step in 1...10 {
            let low = FanPolicy(points: [.init(temperature: 40, speed: 100 - step * 10)], onlyWhenLidClosed: true)
            try await core.setFanPolicy(low, now: at(milliseconds: step * 10))
        }
        let last = try #require(fans.targets.last?.first)
        #expect(last >= 5000 - 5.000_001)
    }

    @Test func risingStaysImmediate() async throws {
        let fans = FakeFans(temperature: 50)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(middle, now: at(0))
        #expect(fans.targets.last == [1000])
        fans.set(temperature: 80)
        await core.updateFans(now: at(milliseconds: 10))
        #expect(fans.targets.last == [5000])
    }

    @Test func speedFromPercentSpansTheFansRange() {
        let fan = FanReading(rpm: 0, minimum: 1000, maximum: 5000)
        #expect(FanCurve.speed(percent: 0, fan: fan) == 1000)
        #expect(FanCurve.speed(percent: 50, fan: fan) == 3000)
        #expect(FanCurve.speed(percent: 100, fan: fan) == 5000)
    }

    @Test func curveFollowsTheHottestSensor() async throws {
        let fans = FakeFans(temperature: 45)
        fans.set(hottest: 50)
        fans.set(group: .cpu, 50)
        fans.set(group: .battery, 41)
        fans.set(group: .ssd, 62.5)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(standard, now: at(0))
        #expect(fans.targets == [[3000]])  // min + 50 % of the range, at the SSD's 62.5 °C
        let status = await core.coolingStatus()
        #expect(status.override == nil)
        #expect(status.hottestTemperature == 62.5)
        #expect(status.hottestGroup == .ssd)
        #expect(status.groupTemperatures == [.cpu: 50, .battery: 41, .ssd: 62.5])
        #expect(status.cpuTemperature == 45)
        #expect(status.hottestCPUTemperature == 50)
        #expect(status.control == .controlling)
    }

    /// Without any group value (as from a source that reads only the CPU), the average is the input, as before.
    @Test func curveFallsBackToTheAverageWithoutTheHottest() async throws {
        let fans = FakeFans(temperature: 62.5)
        fans.set(hottest: 90)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(standard, now: at(0))
        #expect(fans.targets == [[3000]])
        let status = await core.coolingStatus()
        #expect(status.hottestTemperature == nil)
        #expect(status.hottestGroup == nil)
        #expect(status.control == .controlling)
    }

    @Test func noTemperatureAtAllIsStillAFault() async throws {
        let fans = FakeFans(temperature: nil)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(standard, now: at(0))
        #expect(fans.targets.isEmpty)
        #expect(await core.coolingStatus().control == .retrying)
    }

    @Test func floorAppliesInTheHelper() async throws {
        let fans = FakeFans(temperature: 90)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(FanPolicy(points: [.init(temperature: 40, speed: 0)], onlyWhenLidClosed: true), now: at(0))
        #expect(fans.targets == [[4200]])  // 80 % of the range
    }

    @Test func floorFollowsTheHottestSensor() async throws {
        let fans = FakeFans(temperature: 60)
        fans.set(group: .cpu, 62)
        fans.set(group: .gpu, 90)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(FanPolicy(points: [.init(temperature: 40, speed: 0)], onlyWhenLidClosed: true), now: at(0))
        #expect(fans.targets == [[4200]])
    }

    @Test func warmCaseSpeedsUpTheFansBelowTheCurve() async throws {
        let fans = FakeFans(temperature: 45)
        fans.set(group: .cpu, 45)
        fans.set(group: .airflow, 41)
        let (core, _) = try await enabled(fans: fans)
        let policy = FanPolicy(points: standard.points, onlyWhenLidClosed: true, caseRamp: .standard)
        try await core.setFanPolicy(policy, now: at(0))
        #expect(fans.targets == [[3000]])  // 50 % from the case at 41 °C; the curve alone gives 0 % at 45 °C
        #expect(await core.coolingStatus().override == nil)
    }

    @Test func hotBatteryRunsFullSpeedAtOnce() async throws {
        let fans = FakeFans(temperature: 40)
        fans.set(group: .battery, 45)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(standard, now: at(0))
        #expect(fans.targets == [[5000]])
        #expect(await core.coolingStatus().override == .hotBattery)
    }

    @Test func hotBatteryEndsAfterThirtySecondsBelow43() async throws {
        let fans = FakeFans(temperature: 40)
        fans.set(group: .battery, 46)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(middle, now: at(0))
        #expect(fans.targets.last == [5000])
        fans.set(group: .battery, 44)  // between 43 and 45 it holds
        await core.updateFans(now: at(30))
        #expect(fans.targets.last == [5000])
        fans.set(group: .battery, 42.9)
        await core.updateFans(now: at(33))
        await core.updateFans(now: at(60))
        #expect(fans.targets.last == [5000])
        #expect(await core.coolingStatus().override == .hotBattery)
        await core.updateFans(now: at(63))
        #expect(fans.targets.last == [4850])
        #expect(await core.coolingStatus().override == nil)
    }

    @Test func hotCoreComesBeforeHotBattery() async throws {
        let fans = FakeFans(temperature: 70)
        fans.set(hottest: 100)
        fans.set(group: .battery, 50)
        let (core, _) = try await enabled(fans: fans)
        try await core.setFanPolicy(middle, now: at(0))
        #expect(await core.coolingStatus().override == .hotBattery)
        await core.updateFans(now: at(12))
        #expect(await core.coolingStatus().override == .hotCore)
    }

    @Test func hotBatteryComesBeforeTheSystemLevel() async throws {
        let fans = FakeFans(temperature: 70)
        fans.set(group: .battery, 50)
        let (core, _) = try await enabled(fans: fans, thermal: FakeThermal(.serious))
        try await core.setFanPolicy(middle, now: at(0))
        #expect(await core.coolingStatus().override == .hotBattery)
        fans.set(group: .battery, 30)
        await core.updateFans(now: at(40))
        #expect(await core.coolingStatus().override == .hotBattery)
        await core.updateFans(now: at(70))
        #expect(await core.coolingStatus().override == .system)
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

/// Fan control that does not let go: faults hand the fans to macOS, and the helper takes them back by itself.
@Suite struct FanRetryTests {
    private let t0 = SuspendingClock.now
    private let curve = FanPolicy(points: [.init(temperature: 60, speed: 0), .init(temperature: 80, speed: 100)],
                                  onlyWhenLidClosed: true)

    private func at(_ seconds: Int) -> SuspendingClock.Instant { t0.advanced(by: .seconds(seconds)) }

    private func enabled(_ fans: FakeFans = FakeFans(), follows: Bool = true) async throws -> (HelperCore, FakeFans, FakeStore) {
        fans.followsTargets = follows
        let store = FakeStore()
        let core = HelperCore(runner: FakeRunner(), store: store, originals: FakeOriginalStore(), fans: fans, fanStepDown: 150)
        try await core.enable(lowPowerOnBattery: false, now: t0)
        return (core, fans, store)
    }

    /// Three failed writes, 30 seconds apart, ending at `at(60)`.
    private func stopped() async throws -> (HelperCore, FakeFans, FakeStore) {
        let rig = try await enabled()
        rig.1.failSet()
        try await rig.0.setFanPolicy(curve, now: at(0))
        await rig.0.updateFans(now: at(30))
        await rig.0.updateFans(now: at(60))
        return rig
    }

    private func ticks(_ core: HelperCore, from: Int, to: Int) async {
        for second in stride(from: from, through: to, by: 3) { await core.updateFans(now: at(second)) }
    }

    @Test func failedWriteRetriesAfterThirtySeconds() async throws {
        let (core, fans, store) = try await enabled()
        fans.failSet()
        try await core.setFanPolicy(curve, now: at(0))
        #expect(fans.releaseCount == 1)
        #expect(await core.coolingStatus().control == .retrying)
        fans.failSet(false)
        await ticks(core, from: 3, to: 27)
        await core.updateFans(now: at(29))
        #expect(fans.targets.isEmpty)
        await core.updateFans(now: at(30))
        #expect(fans.targets == [[3000]])
        #expect(store.saved?.fansManual == true)
        let status = await core.coolingStatus()
        #expect(status.control == .controlling)
        #expect(status.problem == nil)
    }

    @Test func threeFaultsInARowStop() async throws {
        let (core, fans, _) = try await enabled()
        fans.failSet()
        try await core.setFanPolicy(curve, now: at(0))
        await core.updateFans(now: at(30))
        #expect(await core.coolingStatus().control == .retrying)
        await core.updateFans(now: at(60))
        let status = await core.coolingStatus()
        #expect(status.control == .stopped)
        #expect(status.problem?.hasPrefix("Could not set the fan speed") == true)
        #expect(!fans.isHeld)
    }

    @Test func sixtyQuietSecondsResetTheCount() async throws {
        let (core, fans, _) = try await enabled()
        fans.failSet()
        try await core.setFanPolicy(curve, now: at(0))
        fans.failSet(false)
        await ticks(core, from: 30, to: 90)  // holds for 60 seconds
        fans.failSet()
        await core.updateFans(now: at(93))
        await core.updateFans(now: at(123))
        #expect(await core.coolingStatus().control == .retrying)
    }

    @Test func shortHoldsStillCount() async throws {
        let (core, fans, _) = try await enabled()
        fans.failSet()
        try await core.setFanPolicy(curve, now: at(0))
        fans.failSet(false)
        await ticks(core, from: 30, to: 60)
        fans.failSet()
        await core.updateFans(now: at(63))
        await core.updateFans(now: at(93))
        #expect(await core.coolingStatus().control == .stopped)
    }

    @Test func stoppedTriesEveryFiveMinutes() async throws {
        let (core, fans, _) = try await stopped()
        fans.failSet(false)
        await ticks(core, from: 63, to: 357)
        await core.updateFans(now: at(359))
        #expect(fans.targets.isEmpty)
        await core.updateFans(now: at(360))
        #expect(fans.targets == [[3000]])
        await ticks(core, from: 363, to: 417)
        #expect(await core.coolingStatus().control == .stopped)
        await core.updateFans(now: at(420))
        let status = await core.coolingStatus()
        #expect(status.control == .controlling)
        #expect(status.problem == nil)
    }

    @Test func newPolicyRestartsAtOnce() async throws {
        let (core, fans, _) = try await stopped()
        fans.failSet(false)
        try await core.setFanPolicy(curve, now: at(63))
        #expect(fans.targets == [[3000]])
        #expect(await core.coolingStatus().control == .controlling)
    }

    @Test func newTurnOnRestarts() async throws {
        let (core, fans, _) = try await stopped()
        fans.failSet(false)
        try await core.disable()
        try await core.enable(lowPowerOnBattery: false, now: at(63))
        try await core.setFanPolicy(curve, now: at(63))
        #expect(fans.targets == [[3000]])
    }

    /// The first reading after the write sees the fan below its target at 3 s; 15 seconds later it is a fault.
    @Test func laggingFanForFifteenSecondsIsAFault() async throws {
        let fans = FakeFans(temperature: 80, fans: [FanReading(rpm: 1000, minimum: 1000, maximum: 5000)])
        let (core, _, store) = try await enabled(fans, follows: false)
        try await core.setFanPolicy(curve, now: at(0))
        #expect(fans.targets == [[5000]])
        await ticks(core, from: 3, to: 15)
        #expect(fans.isHeld)
        #expect(await core.coolingStatus().control == .controlling)
        await core.updateFans(now: at(18))
        #expect(!fans.isHeld)
        #expect(store.saved?.fansManual == nil)
        #expect(fans.targets.count == 6)
        let status = await core.coolingStatus()
        #expect(status.control == .retrying)
        #expect(status.problem?.contains("Fan 1") == true)
    }

    /// Ticks that queued behind a slow take-over run back to back: many lagging readings in 2 seconds are no fault.
    @Test func bunchedTicksDoNotFault() async throws {
        let fans = FakeFans(temperature: 80, fans: [FanReading(rpm: 1000, minimum: 1000, maximum: 5000)])
        let (core, _, _) = try await enabled(fans, follows: false)
        try await core.setFanPolicy(curve, now: at(0))
        for millisecond in stride(from: 3000, through: 5000, by: 250) {
            await core.updateFans(now: t0.advanced(by: .milliseconds(millisecond)))
        }
        #expect(fans.isHeld)
        #expect(await core.coolingStatus().control == .controlling)
    }

    @Test func spinningUpFanIsLeftAlone() async throws {
        let slow = FanReading(rpm: 1000, minimum: 1000, maximum: 5000)
        let fans = FakeFans(temperature: 80, fans: [slow])
        let (core, _, _) = try await enabled(fans, follows: false)
        try await core.setFanPolicy(curve, now: at(0))
        await ticks(core, from: 3, to: 9)
        fans.set(fans: [FanReading(rpm: 4900, minimum: 1000, maximum: 5000)])
        await ticks(core, from: 12, to: 60)
        #expect(fans.isHeld)
        #expect(await core.coolingStatus().control == .controlling)
    }

    @Test func fasterThanTargetIsFine() async throws {
        let fans = FakeFans(temperature: 60, fans: [FanReading(rpm: 5000, minimum: 1000, maximum: 5000)])
        let (core, _, _) = try await enabled(fans, follows: false)
        try await core.setFanPolicy(curve, now: at(0))
        await ticks(core, from: 3, to: 60)
        #expect(fans.isHeld)
        #expect(Set(fans.targets) == [[1000]])
    }

    @Test func fanWithNoRangeIsSkipped() async throws {
        let fans = FakeFans(temperature: 80, fans: [FanReading(rpm: 0, minimum: 2000, maximum: 2000)])
        let (core, _, _) = try await enabled(fans, follows: false)
        try await core.setFanPolicy(curve, now: at(0))
        await ticks(core, from: 3, to: 60)
        #expect(fans.isHeld)
        #expect(Set(fans.targets) == [[2000]])
        #expect(await core.coolingStatus().control == .controlling)
    }

    /// A fan that reads 0 rpm while it should turn is a fault, but one every retry at most, never one per tick.
    @Test func fanReadingZeroDoesNotStormFaults() async throws {
        let fans = FakeFans(temperature: 80, fans: [FanReading(rpm: 0, minimum: 1000, maximum: 5000)])
        let (core, _, _) = try await enabled(fans, follows: false)
        try await core.setFanPolicy(curve, now: at(0))
        await ticks(core, from: 3, to: 120)
        // Writes at 0, 48 and 96; each lags from the next reading for 15 seconds, then waits 30; the third fault stops.
        #expect(fans.releaseCount == 3)
        #expect(await core.coolingStatus().control == .stopped)
    }

    @Test func sleepGapDoesNotDoubleFire() async throws {
        let (core, fans, _) = try await enabled()
        fans.failSet()
        try await core.setFanPolicy(curve, now: at(0))
        fans.failSet(false)
        #expect(await core.coolingStatus().control == .retrying)
        await core.updateFans(now: at(3 * 3600))
        #expect(fans.targets == [[3000]])
        #expect(await core.coolingStatus().control == .controlling)
        await core.updateFans(now: at(3 * 3600 + 3))
        #expect(fans.targets.count == 2)
        #expect(fans.releaseCount == 1)
    }

    @Test func openLidIsIdleNotAFault() async throws {
        let (core, fans, _) = try await enabled()
        try await core.setFanPolicy(curve, now: at(0))
        fans.set(lidClosed: false)
        await ticks(core, from: 3, to: 300)
        let status = await core.coolingStatus()
        #expect(status.control == .idle)
        #expect(status.problem == nil)
        #expect(!fans.isHeld)
        fans.set(lidClosed: true)
        await core.updateFans(now: at(303))
        #expect(fans.isHeld)
        #expect(await core.coolingStatus().control == .controlling)
    }

    /// Time with the lid open is not control without a fault, so it does not reset the count.
    @Test func openLidTimeDoesNotCountAsQuiet() async throws {
        let (core, fans, _) = try await enabled()
        fans.failSet()
        try await core.setFanPolicy(curve, now: at(0))
        fans.failSet(false)
        await ticks(core, from: 30, to: 45)
        fans.set(lidClosed: false)
        await ticks(core, from: 48, to: 300)
        fans.set(lidClosed: true)
        await ticks(core, from: 303, to: 330)
        fans.failSet()
        await core.updateFans(now: at(333))
        await core.updateFans(now: at(363))
        #expect(await core.coolingStatus().control == .stopped)
    }

    @Test func openLidWhileStoppedShowsIdle() async throws {
        let (core, fans, _) = try await stopped()
        fans.set(lidClosed: false)
        await core.updateFans(now: at(63))
        #expect(await core.coolingStatus().control == .idle)
        fans.set(lidClosed: true)
        await core.updateFans(now: at(66))
        #expect(await core.coolingStatus().control == .stopped)
    }

    @Test func lostTemperatureIsAFault() async throws {
        let (core, fans, _) = try await enabled()
        try await core.setFanPolicy(curve, now: at(0))
        fans.set(temperature: nil)
        await core.updateFans(now: at(3))
        #expect(!fans.isHeld)
        let status = await core.coolingStatus()
        #expect(status.control == .retrying)
        #expect(status.problem == "Cannot read the temperature sensors.")
        fans.set(temperature: 70)
        await core.updateFans(now: at(6))
        #expect(!fans.isHeld)  // waits for the retry
        await core.updateFans(now: at(33))
        #expect(fans.isHeld)
    }

    /// A fan whose keys fail to read drops out of the reading; its neighbour's target must never land on it.
    @Test func droppedFanIsAFault() async throws {
        let first = FanReading(rpm: 1000, minimum: 1000, maximum: 5000, index: 0)
        let second = FanReading(rpm: 1200, minimum: 1200, maximum: 6000, index: 1)
        let fans = FakeFans(fans: [first, second])
        let (core, _, store) = try await enabled(fans)
        try await core.setFanPolicy(curve, now: at(0))
        #expect(fans.targets == [[3000, 3600]])
        fans.set(fans: [second])
        await core.updateFans(now: at(3))
        #expect(fans.targets.count == 1)
        #expect(!fans.isHeld)
        #expect(store.saved?.fansManual == nil)
        #expect(await core.coolingStatus().control == .retrying)
        // Back to both fans: the retry takes them again.
        fans.set(fans: [first, second])
        await core.updateFans(now: at(33))
        #expect(fans.targets.last == [3000, 3600])
    }

    @Test func droppedLastFanIsAFault() async throws {
        let first = FanReading(rpm: 1000, minimum: 1000, maximum: 5000, index: 0)
        let second = FanReading(rpm: 1200, minimum: 1200, maximum: 6000, index: 1)
        let fans = FakeFans(fans: [first, second])
        let (core, _, _) = try await enabled(fans)
        try await core.setFanPolicy(curve, now: at(0))
        fans.set(fans: [first])
        await core.updateFans(now: at(3))
        #expect(fans.targets.count == 1)
        #expect(!fans.isHeld)
    }

    @Test func fanOutOfPlaceIsNeverWritten() async throws {
        let fans = FakeFans(fans: [FanReading(rpm: 1200, minimum: 1200, maximum: 6000, index: 1)])
        let (core, _, _) = try await enabled(fans)
        try await core.setFanPolicy(curve, now: at(0))
        #expect(fans.targets.isEmpty)
        #expect(await core.coolingStatus().control == .retrying)
    }

    /// A fan whose keys never read is missing from the first reading too. Taking the others would leave it
    /// with the system's control switched off and no target, so nothing is written at all.
    @Test func fanThatNeverReadsIsAFaultFromTheFirstReading() async throws {
        let first = FanReading(rpm: 1000, minimum: 1000, maximum: 5000, index: 0)
        let fans = FakeFans(fans: [first], fanCount: 2)
        let (core, _, store) = try await enabled(fans)
        try await core.setFanPolicy(curve, now: at(0))
        #expect(fans.targets.isEmpty)
        #expect(!fans.isHeld)
        #expect(store.saved?.fansManual == nil)
        let status = await core.coolingStatus()
        #expect(status.control == .retrying)
        #expect(status.problem == "Could not read every fan.")
        await ticks(core, from: 3, to: 120)
        #expect(fans.targets.isEmpty)
        #expect(await core.coolingStatus().control == .stopped)
    }

    @Test func noFansReadIsAFault() async throws {
        let fans = FakeFans(fans: [])
        let (core, _, _) = try await enabled(fans)
        try await core.setFanPolicy(curve, now: at(0))
        #expect(fans.targets.isEmpty)
        #expect(await core.coolingStatus().control == .retrying)
    }

    /// Fans that macOS did not take back must not stay frozen at the last target while nobody drives them:
    /// until the hand-back works, every tick runs them at full speed and tries the hand-back again.
    @Test func failedReleaseRunsTheFansAtFullSpeedUntilItWorks() async throws {
        let first = FanReading(rpm: 1000, minimum: 1000, maximum: 5000, index: 0)
        let second = FanReading(rpm: 1200, minimum: 1200, maximum: 6000, index: 1)
        let fans = FakeFans(fans: [first, second])
        let (core, _, store) = try await enabled(fans)
        try await core.setFanPolicy(curve, now: at(0))
        #expect(fans.targets == [[3000, 3600]])
        fans.failRelease()
        fans.set(temperature: nil)
        await core.updateFans(now: at(3))  // a fault whose hand-back fails
        #expect(fans.releaseCount == 1)
        #expect(fans.heldWrites == [[5000, 6000]])
        #expect(store.saved?.fansManual == true)
        let status = await core.coolingStatus()
        #expect(status.problem?.hasPrefix("Could not hand the fans back to macOS") == true)
        #expect(status.control == .retrying)
        #expect(status.handBackFailed)
        fans.set(temperature: 70)
        await core.updateFans(now: at(6))
        await core.updateFans(now: at(9))
        #expect(fans.releaseCount == 3)
        #expect(fans.heldWrites.count == 3)
        #expect(fans.heldWrites.last == [5000, 6000])
        #expect(store.saved?.fansManual == true)
        fans.failRelease(false)
        await core.updateFans(now: at(12))
        #expect(!fans.isHeld)
        #expect(store.saved?.fansManual == nil)
        #expect(await !core.coolingStatus().handBackFailed)
        await ticks(core, from: 15, to: 27)
        #expect(fans.heldWrites.count == 3)
        #expect(fans.targets.count == 1)  // the full-speed path never took the fans over
        #expect(fans.takeOverCount == 2)
        #expect(await core.coolingStatus().problem == "Cannot read the temperature sensors.")
    }

    /// A hand-back that failed halfway leaves one fan with macOS. The full-speed path leaves that fan to macOS
    /// and never takes it back, which could block a tick for seconds and fight macOS every 3 seconds.
    @Test func failedReleaseLeavesAFanMacOSHasAlone() async throws {
        let first = FanReading(rpm: 1000, minimum: 1000, maximum: 5000, index: 0)
        let second = FanReading(rpm: 1200, minimum: 1200, maximum: 6000, index: 1)
        let fans = FakeFans(fans: [first, second])
        let (core, _, _) = try await enabled(fans)
        try await core.setFanPolicy(curve, now: at(0))
        let takeOvers = fans.takeOverCount
        fans.failRelease()
        fans.set(manual: false, fan: 1)  // macOS has fan 2 back
        fans.set(temperature: nil)
        await core.updateFans(now: at(3))
        await core.updateFans(now: at(6))
        #expect(fans.heldWrites == [[5000, nil], [5000, nil]])
        #expect(fans.takeOverCount == takeOvers)
        #expect(fans.targets.count == 1)
    }

    /// A fan that drops out of the reading keeps the maximum it was last read with.
    @Test func failedReleaseUsesTheLastKnownMaximum() async throws {
        let first = FanReading(rpm: 1000, minimum: 1000, maximum: 5000, index: 0)
        let second = FanReading(rpm: 1200, minimum: 1200, maximum: 6000, index: 1)
        let fans = FakeFans(fans: [first, second])
        let (core, _, _) = try await enabled(fans)
        try await core.setFanPolicy(curve, now: at(0))
        fans.failRelease()
        fans.set(fans: [first])
        await core.updateFans(now: at(3))
        #expect(fans.heldWrites.last == [5000, 6000])
    }

    @Test func failedReleaseAfterSwitchOffRunsTheFansAtFullSpeed() async throws {
        let (core, fans, store) = try await enabled()
        try await core.setFanPolicy(curve, now: at(0))
        fans.failRelease()
        try await core.disable()
        #expect(fans.heldWrites == [[5000]])
        #expect(store.saved == SavedState(fansManual: true))
        await core.updateFans(now: at(3))
        #expect(fans.heldWrites.count == 2)
        fans.failRelease(false)
        await core.updateFans(now: at(6))
        #expect(!fans.isHeld)
        #expect(store.saved == nil)
        await core.updateFans(now: at(9))
        #expect(fans.heldWrites.count == 2)
        #expect(fans.targets.count == 1)
    }

    /// The take-over is on disk before the first write of a retry, as on the first take-over.
    @Test func retryRecordsTheTakeOverBeforeWriting() async throws {
        let log = EventLog()
        let fans = FakeFans(log: log)
        fans.followsTargets = true
        let core = HelperCore(runner: FakeRunner(), store: FakeStore(log: log), originals: FakeOriginalStore(), fans: fans, fanStepDown: 150)
        try await core.enable(lowPowerOnBattery: false, now: t0)
        fans.failSet()
        try await core.setFanPolicy(curve, now: at(0))
        fans.failSet(false)
        let before = log.events.count
        await core.updateFans(now: at(30))
        #expect(Array(log.events.dropFirst(before)) == ["save fans held", "set targets"])
        #expect(fans.targets == [[3000]])
    }

    @Test func statusDoesNotRetry() async throws {
        let (core, fans, _) = try await enabled()
        fans.failSet()
        try await core.setFanPolicy(curve, now: at(0))
        fans.failSet(false)
        for _ in 0..<5 { _ = await core.coolingStatus() }
        #expect(fans.targets.isEmpty)
        #expect(await core.coolingStatus().control == .retrying)
    }
}
