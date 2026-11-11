import Foundation
import Testing
@testable import ClamDownHelperKit

@Suite struct HelperCoreTests {
    /// `prior` is the battery profile's Low Power Mode before ClamDown touches it (nil = unreadable).
    /// `sleep` is the user's own `SleepDisabled` value (nil = the line is missing from `pmset -g`).
    private func make(prior: Bool? = false, saved: SavedState? = nil, loadFails: Bool = false, sleep: Bool? = false) -> (HelperCore, FakeRunner, FakeStore) {
        let runner = FakeRunner(batteryLowPower: prior, sleepDisabled: sleep)
        let store = FakeStore(initial: saved, loadFails: loadFails)
        return (HelperCore(runner: runner, store: store), runner, store)
    }

    @Test func enableSavesPriorThenDisablesSleepThenSetsLowPower() async throws {
        let (core, runner, store) = make()
        try await core.enable(lowPowerOnBattery: true)
        #expect(runner.commands == [.readGlobal, .readCustom, .setSleepDisabled(true), .setBatteryLowPowerMode(true)])
        #expect(store.saved == SavedState(batteryLowPowerMode: false, sleepDisabled: false))
        #expect(await core.isEnabled)
    }

    @Test func enableWithoutLowPowerOptionLeavesLowPowerAlone() async throws {
        let (core, runner, _) = make()
        try await core.enable(lowPowerOnBattery: false)
        #expect(runner.commands == [.readGlobal, .readCustom, .setSleepDisabled(true)])
        #expect(await core.isEnabled)
    }

    @Test func enableRollsBackWhenLowPowerCommandFails() async {
        let (core, runner, store) = make()
        runner.fail(.setBatteryLowPowerMode(true))
        await #expect(throws: FakeFailure.self) { try await core.enable(lowPowerOnBattery: true) }
        #expect(Array(runner.commands.suffix(2)) == [.setSleepDisabled(false), .setBatteryLowPowerMode(false)])
        #expect(store.saved == nil)
        #expect(await core.isEnabled == false)
    }

    @Test func enableRollsBackWhenSleepCommandFails() async {
        let (core, runner, store) = make()
        runner.fail(.setSleepDisabled(true))
        await #expect(throws: FakeFailure.self) { try await core.enable(lowPowerOnBattery: true) }
        #expect(runner.commands.contains(.setSleepDisabled(false)))
        #expect(!runner.commands.contains(.setBatteryLowPowerMode(true)))
        #expect(store.saved == nil)
        #expect(await core.isEnabled == false)
    }

    @Test func rollbackPutsBackTheUsersOwnSleepSettingWhenItWasOn() async {
        let (core, runner, _) = make(sleep: true)
        runner.fail(.setBatteryLowPowerMode(true))
        await #expect(throws: FakeFailure.self) { try await core.enable(lowPowerOnBattery: true) }
        #expect(Array(runner.commands.suffix(2)) == [.setSleepDisabled(true), .setBatteryLowPowerMode(false)])
        #expect(await core.isEnabled == false)
    }

    @Test func enableSkipsLowPowerWhenPriorValueUnreadable() async throws {
        let (core, runner, store) = make(prior: nil)
        try await core.enable(lowPowerOnBattery: true)
        #expect(runner.commands == [.readGlobal, .readCustom, .setSleepDisabled(true)])
        #expect(store.saved == SavedState(batteryLowPowerMode: nil, sleepDisabled: false))
        #expect(await core.isEnabled)
    }

    @Test func enableWhileEnabledOnlyReappliesLowPower() async throws {
        let (core, runner, _) = make()
        try await core.enable(lowPowerOnBattery: false)
        try await core.enable(lowPowerOnBattery: true)
        #expect(runner.commands == [.readGlobal, .readCustom, .setSleepDisabled(true), .setBatteryLowPowerMode(true)])
    }

    @Test func enableFailsWhenSleepSettingIsUnreadableAndChangesNothing() async {
        let (core, runner, store) = make(sleep: nil)
        await #expect(throws: HelperError.unreadableSleepSetting) { try await core.enable(lowPowerOnBattery: true) }
        #expect(runner.commands == [.readGlobal])
        #expect(store.saved == nil)
        #expect(await core.isEnabled == false)
    }

    @Test func disableRestoresPriorValueAndClearsState() async throws {
        let (core, runner, store) = make(prior: true)
        try await core.enable(lowPowerOnBattery: true)
        try await core.disable()
        #expect(Array(runner.commands.suffix(2)) == [.setSleepDisabled(false), .setBatteryLowPowerMode(true)])
        #expect(store.saved == nil)
        #expect(await core.isEnabled == false)
    }

    @Test func disableRestoresUsersOwnSleepSettingNotAlwaysOff() async throws {
        let (core, runner, store) = make(sleep: true)
        try await core.enable(lowPowerOnBattery: false)
        #expect(store.saved?.sleepDisabled == true)
        try await core.disable()
        #expect(Array(runner.commands.suffix(2)) == [.setSleepDisabled(true), .setBatteryLowPowerMode(false)])
        #expect(store.saved == nil)
    }

    @Test func disableWhenNotEnabledStillClearsSleepDisabled() async throws {
        let (core, runner, _) = make()
        try await core.disable()
        #expect(runner.commands == [.setSleepDisabled(false)])
    }

    @Test func setLowPowerFalseRestoresPrior() async throws {
        let (core, runner, _) = make(prior: false)
        try await core.enable(lowPowerOnBattery: true)
        try await core.setLowPowerOnBattery(false)
        #expect(runner.commands.last == .setBatteryLowPowerMode(false))
    }

    @Test func setLowPowerTrueAppliesAfterEnableWithoutOption() async throws {
        let (core, runner, _) = make(prior: false)
        try await core.enable(lowPowerOnBattery: false)
        try await core.setLowPowerOnBattery(true)
        #expect(runner.commands.last == .setBatteryLowPowerMode(true))
    }

    @Test func setLowPowerWhenNotEnabledThrows() async {
        let (core, _, _) = make()
        await #expect(throws: HelperError.notEnabled) { try await core.setLowPowerOnBattery(true) }
    }

    @Test func recoverOnStartRestoresSavedStateAndResetsSleep() async throws {
        let (core, runner, store) = make(saved: SavedState(batteryLowPowerMode: true))
        try await core.recoverOnStart()
        #expect(runner.commands == [.setBatteryLowPowerMode(true), .setSleepDisabled(false)])
        #expect(store.saved == nil)
    }

    @Test func recoverOnStartRestoresUsersOwnSleepSetting() async throws {
        let (core, runner, store) = make(saved: SavedState(sleepDisabled: true))
        try await core.recoverOnStart()
        #expect(runner.commands == [.setSleepDisabled(true)])
        #expect(store.saved == nil)
    }

    @Test func recoverOnStartWithoutSavedStateOnlyResetsSleep() async throws {
        let (core, runner, _) = make()
        try await core.recoverOnStart()
        #expect(runner.commands == [.setSleepDisabled(false)])
    }

    @Test func recoverOnStartIgnoresUnreadableStateAndStillResetsSleep() async throws {
        let (core, runner, _) = make(loadFails: true)
        try await core.recoverOnStart()
        #expect(runner.commands == [.setSleepDisabled(false)])
    }
}
