import Foundation
import Testing
import ClamDownSensors
import ClamDownShared
@testable import ClamDownHelperKit

/// The saved state is what puts the user's sleep setting back after a crash. Nothing may write over a session that
/// still has to be put back, and the fans go back to macOS only once the mode really is off.
@Suite struct SavedStateSafetyTests {
    private let lidOpenCurve = FanPolicy(points: [.init(temperature: 60, speed: 0), .init(temperature: 80, speed: 100)],
                                         onlyWhenLidClosed: false)
    private let session = SavedState(batteryLowPowerMode: false, sleepDisabled: false)

    /// A recovery that failed keeps its session on disk; a fan-only session adds its take-over to it.
    @Test func aFanOnlySessionKeepsTheSessionAFailedRecoveryLeft() async throws {
        let runner = FakeRunner(sleepDisabled: true)
        runner.fail(.setSleepDisabled(false), times: 1)
        let store = FakeStore(initial: session)
        let fans = FakeFans(lidClosed: false)
        let core = HelperCore(runner: runner, store: store, originals: FakeOriginalStore(), fans: fans)
        await #expect(throws: FakeFailure.self) { try await core.recoverOnStart() }
        #expect(store.saved == session)

        try await core.setFanPolicy(lidOpenCurve, owner: UUID())
        #expect(fans.isHeld)
        #expect(store.saved == SavedState(batteryLowPowerMode: false, sleepDisabled: false, fansManual: true))

        try await core.setFanPolicy(FanPolicy(points: []))
        #expect(!fans.isHeld)
        #expect(store.saved == session)

        // The retry puts the user's value back.
        try await core.disable()
        #expect(runner.commands.suffix(2) == [.setBatteryLowPowerMode(false), .setSleepDisabled(false)])
        #expect(store.saved == nil)
    }

    /// A damaged file stands for "sleep allowed" in a fan-only session too.
    @Test func aFanOnlySessionOverADamagedFileKeepsSleepAllowedOnRecord() async throws {
        let runner = FakeRunner(sleepDisabled: true)
        runner.fail(.setSleepDisabled(false), times: 1)
        let store = FakeStore(initial: nil, loadFails: true)
        let core = HelperCore(runner: runner, store: store, originals: FakeOriginalStore(), fans: FakeFans(lidClosed: false))
        await #expect(throws: FakeFailure.self) { try await core.recoverOnStart() }
        try await core.setFanPolicy(lidOpenCurve)
        #expect(store.saved == SavedState(sleepDisabled: false, fansManual: true))
    }

    /// A Turn On that fails after a failed recovery puts the pending session back on disk instead of clearing it.
    @Test func aFailedTurnOnKeepsThePendingSession() async throws {
        let runner = FakeRunner(sleepDisabled: true)
        runner.fail(.setSleepDisabled(false), times: 1)
        runner.fail(.setSleepDisabled(true), times: 1)
        let store = FakeStore(initial: session)
        let originals = FakeOriginalStore()
        let core = HelperCore(runner: runner, store: store, originals: originals)
        await #expect(throws: FakeFailure.self) { try await core.recoverOnStart() }
        await #expect(throws: FakeFailure.self) { try await core.enable(lowPowerOnBattery: false) }
        #expect(store.saved == session)
        // The next Turn On still takes the user's value from the record, not from the current setting.
        try await core.enable(lowPowerOnBattery: false)
        try await core.disable()
        #expect(runner.commands.suffix(2).first == .setSleepDisabled(false))
    }

    /// A Turn On over a damaged file does not take the current setting, maybe ClamDown's own, as the user's.
    @Test func aTurnOnOverADamagedFileTakesSleepAllowedAsTheUsersValue() async throws {
        let runner = FakeRunner(sleepDisabled: true)
        let store = FakeStore(initial: nil, loadFails: true)
        let core = HelperCore(runner: runner, store: store, originals: FakeOriginalStore())
        try await core.enable(lowPowerOnBattery: false)
        #expect(!runner.commands.contains(.readGlobal))
        try await core.disable()
        #expect(runner.commands.last == .setSleepDisabled(false))
    }

    /// A switch-off that fails keeps the mode on, and the mode keeps driving the fans instead of handing them back
    /// and taking them again on every tick.
    @Test func aFailedSwitchOffLeavesTheFansDriven() async throws {
        let runner = FakeRunner()
        let fans = FakeFans()
        let core = HelperCore(runner: runner, store: FakeStore(), originals: FakeOriginalStore(), fans: fans)
        try await core.enable(lowPowerOnBattery: false)
        try await core.setFanPolicy(lidOpenCurve)
        runner.fail(.setSleepDisabled(false))
        for _ in 0..<5 {
            await #expect(throws: FakeFailure.self) { try await core.disable() }
            await core.updateFans()
        }
        #expect(fans.releaseCount == 0)
        #expect(fans.takeOverCount == 1)
        #expect(fans.isHeld)
        #expect(await core.isEnabled)
    }

    /// The helper is about to go: Remove Helper ends a fan-only session, with or without a record of the originals.
    @Test func removingTheHelperEndsAFanOnlySession() async throws {
        let fans = FakeFans(lidClosed: false)
        let store = FakeStore()
        let core = HelperCore(runner: FakeRunner(), store: store, originals: FakeOriginalStore(), fans: fans)
        try await core.setFanPolicy(lidOpenCurve, owner: UUID())
        try await core.restoreOriginalSettings()
        #expect(!fans.isHeld)
        await core.updateFans()
        #expect(!fans.isHeld)
        #expect(store.saved == nil)
    }

    /// launchd stops the helper: the fans go back even when the switch-off itself fails.
    @Test func shutdownHandsTheFansBackEvenWhenTheSwitchOffFails() async throws {
        let runner = FakeRunner()
        let fans = FakeFans()
        let core = HelperCore(runner: runner, store: FakeStore(), originals: FakeOriginalStore(), fans: fans)
        try await core.enable(lowPowerOnBattery: false)
        try await core.setFanPolicy(lidOpenCurve)
        runner.fail(.setSleepDisabled(false))
        await #expect(throws: FakeFailure.self) { try await core.shutdown() }
        #expect(!fans.isHeld)
        await core.updateFans()
        #expect(!fans.isHeld)
    }

    /// Turn On drops a fan-only session's policy: if the mode's own never arrives, macOS keeps the fans.
    @Test func turnOnDropsAFanOnlySessionsPolicy() async throws {
        let fans = FakeFans(lidClosed: false)
        let core = HelperCore(runner: FakeRunner(), store: FakeStore(), originals: FakeOriginalStore(), fans: fans)
        try await core.setFanPolicy(lidOpenCurve, owner: UUID())
        try await core.enable(lowPowerOnBattery: false)
        await core.updateFans()
        #expect(!fans.isHeld)
    }

    /// A fan reporting a broken range would be set to 0 rpm; macOS keeps it instead.
    @Test func aFanWithABrokenRangeIsAFault() async throws {
        let fans = FakeFans(temperature: 90, lidClosed: false, fans: [FanReading(rpm: 0, minimum: 1200, maximum: 0)])
        let core = HelperCore(runner: FakeRunner(), store: FakeStore(), originals: FakeOriginalStore(), fans: fans)
        try await core.setFanPolicy(lidOpenCurve)
        #expect(fans.targets.isEmpty)
        #expect(!fans.isHeld)
        #expect(await core.coolingStatus().problem == "Fan 1 reports no usable speed range.")
    }
}
