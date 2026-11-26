import Foundation
import Testing
@testable import ClamDownHelperKit

@Suite struct HelperCoreTests {
    /// `prior` is the battery profile's Low Power Mode before ClamDown touches it (nil = unreadable).
    /// `sleep` is the user's own `SleepDisabled` value (nil = the line is missing from `pmset -g`).
    private func make(prior: Bool? = false, saved: SavedState? = nil, loadFails: Bool = false, sleep: Bool? = false) -> (HelperCore, FakeRunner, FakeStore) {
        let runner = FakeRunner(batteryLowPower: prior, sleepDisabled: sleep)
        let store = FakeStore(initial: saved, loadFails: loadFails)
        return (HelperCore(runner: runner, store: store, originals: FakeOriginalStore()), runner, store)
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
        let runner = FakeRunner(sleepLine: " SleepDisabled\t\tmaybe\n")
        let store = FakeStore(initial: nil, loadFails: false)
        let core = HelperCore(runner: runner, store: store, originals: FakeOriginalStore())
        await #expect(throws: HelperError.unreadableSleepSetting) { try await core.enable(lowPowerOnBattery: true) }
        #expect(runner.commands == [.readGlobal])
        #expect(store.saved == nil)
        #expect(await core.isEnabled == false)
    }

    /// A fresh Mac prints no `SleepDisabled` line until `disablesleep` was set once (issue #2): that is the default, off.
    @Test func enableTreatsAMissingSleepSettingAsOff() async throws {
        let (core, runner, store) = make(sleep: nil)
        try await core.enable(lowPowerOnBattery: false)
        #expect(runner.commands == [.readGlobal, .readCustom, .setSleepDisabled(true)])
        #expect(store.saved == SavedState(batteryLowPowerMode: false, sleepDisabled: false))
        #expect(await core.isEnabled)
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

    /// While off, the sleep setting is the user's own: an app quit, a reinstall or launchd's stop leaves it alone.
    @Test func disableWhenNotEnabledLeavesTheUsersSettings() async throws {
        let (core, runner, _) = make(sleep: true)
        try await core.disable()
        try await core.shutdown()
        #expect(runner.commands.isEmpty)
    }

    /// A recovery that failed on start leaves the session on disk; the next switch-off finishes it.
    @Test func disableWhenNotEnabledFinishesAFailedRecovery() async throws {
        let (core, runner, store) = make(saved: SavedState(batteryLowPowerMode: false, sleepDisabled: false))
        runner.fail(.setSleepDisabled(false), times: 1)
        await #expect(throws: FakeFailure.self) { try await core.recoverOnStart() }
        #expect(store.saved != nil)
        try await core.disable()
        #expect(runner.commands.last == .setSleepDisabled(false))
        #expect(store.saved == nil)
    }

    @Test func aClosedConnectionSwitchesOffOnlyTheModeItOwns() async throws {
        let (core, _, _) = make()
        let old = UUID(), new = UUID()
        try await core.enable(lowPowerOnBattery: false, owner: old)
        try await core.enable(lowPowerOnBattery: false, owner: new)
        try await core.connectionClosed(old)
        #expect(await core.isEnabled)
        try await core.connectionClosed(new)
        #expect(await core.isEnabled == false)
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

    @Test func recoverOnStartWithoutSavedStateChangesNothing() async throws {
        let (core, runner, _) = make(sleep: true)
        try await core.recoverOnStart()
        #expect(runner.commands.isEmpty)
    }

    @Test func recoverOnStartAfterAFanTakeOverAloneLeavesSleepAlone() async throws {
        let runner = FakeRunner(batteryLowPower: false, sleepDisabled: true)
        let store = FakeStore(initial: SavedState(fansManual: true))
        let fans = FakeFans()
        let core = HelperCore(runner: runner, store: store, originals: FakeOriginalStore(), fans: fans)
        try await core.recoverOnStart()
        #expect(runner.commands.isEmpty)
        #expect(fans.releaseCount == 1)
        #expect(store.saved == nil)
    }

    /// Without an SMC the fans cannot be handed back, so the take-over stays on record for a later start.
    @Test func recoverOnStartKeepsAFanTakeOverItCannotUndo() async throws {
        let (core, runner, store) = make(saved: SavedState(fansManual: true), sleep: true)
        await #expect(throws: HelperError.fansUnreachable) { try await core.recoverOnStart() }
        #expect(runner.commands.isEmpty)
        #expect(store.saved == SavedState(fansManual: true))
    }

    @Test func recoverOnStartIgnoresUnreadableStateAndStillResetsSleep() async throws {
        let (core, runner, _) = make(loadFails: true)
        try await core.recoverOnStart()
        #expect(runner.commands == [.setSleepDisabled(false)])
    }
}
