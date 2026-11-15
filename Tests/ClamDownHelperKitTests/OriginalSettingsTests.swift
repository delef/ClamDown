import Foundation
import Testing
import ClamDownSensors
import ClamDownShared
@testable import ClamDownHelperKit

@Suite struct OriginalSettingsTests {
    /// `prior` is the battery profile's Low Power Mode before ClamDown touches it (nil = unreadable).
    /// `sleep` is the user's own `SleepDisabled` value.
    private func make(
        prior: Bool? = false,
        sleep: Bool? = false,
        original: OriginalSettings? = nil,
        saved: SavedState? = nil,
        fans: FakeFans? = nil
    ) -> (HelperCore, FakeRunner, FakeStore, FakeOriginalStore) {
        let runner = FakeRunner(batteryLowPower: prior, sleepDisabled: sleep)
        let store = FakeStore(initial: saved)
        let originals = FakeOriginalStore(initial: original, runner: runner)
        let core = HelperCore(runner: runner, store: store, originals: originals, fans: fans)
        return (core, runner, store, originals)
    }

    private func recorded(sleep: Bool?, lowPower: Bool?) -> OriginalSettings {
        OriginalSettings(sleepDisabled: sleep, batteryLowPowerMode: lowPower,
                         recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private let curve = FanPolicy(points: [.init(temperature: 60, speed: 0), .init(temperature: 80, speed: 100)], onlyWhenLidClosed: false)

    // MARK: - Recording

    @Test func firstEnableRecordsTheValuesBeforeAnythingChanges() async throws {
        let (core, runner, _, originals) = make(prior: true, sleep: true)
        try await core.enable(lowPowerOnBattery: true)
        #expect(originals.commandsAtSave == [[.readGlobal, .readCustom]])
        #expect(originals.saved?.sleepDisabled == true)
        #expect(originals.saved?.batteryLowPowerMode == true)
        #expect(runner.commands == [.readGlobal, .readCustom, .setSleepDisabled(true), .setBatteryLowPowerMode(true)])
    }

    /// While the mode is off the values are the user's own, so every clean switch-on records them afresh.
    @Test func everyCleanEnableRecordsAfresh() async throws {
        let (core, _, _, originals) = make()
        try await core.enable(lowPowerOnBattery: false)
        try await core.disable()
        try await core.enable(lowPowerOnBattery: true)
        #expect(originals.saveCount == 2)
    }

    /// A setting changed since an earlier switch-on, or a record left by an earlier install, must not come back.
    @Test func anOlderRecordIsReplacedByTheCurrentValues() async throws {
        let (core, _, _, originals) = make(prior: false, sleep: false, original: recorded(sleep: true, lowPower: true))
        try await core.enable(lowPowerOnBattery: true)
        #expect(originals.saved?.sleepDisabled == false)
        #expect(originals.saved?.batteryLowPowerMode == false)
    }

    /// After a session that was never undone the current values may be ClamDown's own: the record and the
    /// session's saved values win over them.
    @Test func aSessionLeftOnDiskKeepsTheRecordAndItsValues() async throws {
        let earlier = recorded(sleep: false, lowPower: false)
        let (core, runner, store, originals) = make(prior: true, sleep: true, original: earlier,
                                                    saved: SavedState(batteryLowPowerMode: false, sleepDisabled: false))
        try await core.enable(lowPowerOnBattery: true)
        #expect(originals.saved == earlier)
        #expect(!runner.commands.contains(.readGlobal))
        #expect(store.saved == SavedState(batteryLowPowerMode: false, sleepDisabled: false))
        try await core.disable()
        #expect(Array(runner.commands.suffix(2)) == [.setSleepDisabled(false), .setBatteryLowPowerMode(false)])
    }

    /// The whole Remove Helper path: a user's own `disablesleep 1` survives the restore and the helper's exit.
    @Test func theUsersOwnSleepDisabledSurvivesRemoval() async throws {
        let (core, runner, _, originals) = make(prior: nil, sleep: true)
        try await core.enable(lowPowerOnBattery: false)
        try await core.disable()
        try await core.restoreOriginalSettings()
        try await core.shutdown()
        #expect(runner.commands.last == .setSleepDisabled(true))
        #expect(originals.saved == nil)
    }

    @Test func failingToRecordRollsBackLikeAFailedSave() async {
        let (core, runner, store, originals) = make()
        originals.failSave()
        await #expect(throws: FakeFailure.self) { try await core.enable(lowPowerOnBattery: true) }
        #expect(!runner.commands.contains(.setSleepDisabled(true)))
        #expect(!runner.commands.contains(.setBatteryLowPowerMode(true)))
        #expect(store.saved == nil)
        #expect(originals.saved == nil)
        #expect(await core.isEnabled == false)
    }

    /// A damaged record must never keep the Mac from staying awake: the values read now replace it.
    @Test func unreadableRecordIsReplacedAndEnableGoesOn() async throws {
        let (core, runner, _, originals) = make()
        originals.failLoad()
        try await core.enable(lowPowerOnBattery: true)
        #expect(runner.commands.contains(.setSleepDisabled(true)))
        #expect(originals.saveCount == 1)
        #expect(await core.isEnabled)
    }

    @Test func unreadableRecordAtRestoreActsLikeSwitchOffAndIsDeleted() async throws {
        let (core, runner, _, originals) = make(original: recorded(sleep: true, lowPower: true))
        try await core.enable(lowPowerOnBattery: false)
        originals.failLoad()
        try await core.restoreOriginalSettings()
        #expect(Array(runner.commands.suffix(2)) == [.setSleepDisabled(false), .setBatteryLowPowerMode(false)])
        #expect(!runner.commands.contains(.setBatteryLowPowerMode(true)))
        #expect(originals.saved == nil)
    }

    // MARK: - Restoring

    @Test func restorePutsBackTheRecordedValuesAndDeletesTheRecord() async throws {
        let (core, runner, _, originals) = make(original: recorded(sleep: true, lowPower: true))
        try await core.restoreOriginalSettings()
        #expect(runner.commands == [.setSleepDisabled(true), .setBatteryLowPowerMode(true)])
        #expect(originals.saved == nil)
        #expect(await core.isEnabled == false)
    }

    @Test func restoreWithUnknownLowPowerLeavesLowPowerAlone() async throws {
        let (core, runner, _, originals) = make(original: recorded(sleep: false, lowPower: nil))
        try await core.restoreOriginalSettings()
        #expect(runner.commands == [.setSleepDisabled(false)])
        #expect(originals.saved == nil)
    }

    @Test func restoreWithUnknownSleepSettingTurnsSleepDisabledOff() async throws {
        let (core, runner, _, _) = make(original: recorded(sleep: nil, lowPower: nil))
        try await core.restoreOriginalSettings()
        #expect(runner.commands == [.setSleepDisabled(false)])
    }

    @Test func failingPmsetKeepsTheRecordAndThrowsButTriesEveryStep() async throws {
        let (core, runner, _, originals) = make(original: recorded(sleep: true, lowPower: true))
        runner.fail(.setSleepDisabled(true), times: 1)
        await #expect(throws: FakeFailure.self) { try await core.restoreOriginalSettings() }
        #expect(runner.commands.contains(.setBatteryLowPowerMode(true)))
        #expect(originals.saved == recorded(sleep: true, lowPower: true))
        // A retry finishes the job and removes the record.
        try await core.restoreOriginalSettings()
        #expect(originals.saved == nil)
    }

    @Test func restoreWithoutARecordActsLikeDisable() async throws {
        let (core, runner, store, originals) = make(prior: true)
        try await core.enable(lowPowerOnBattery: true)
        try originals.delete()
        try await core.restoreOriginalSettings()
        #expect(Array(runner.commands.suffix(2)) == [.setSleepDisabled(false), .setBatteryLowPowerMode(true)])
        #expect(store.saved == nil)
        #expect(await core.isEnabled == false)
    }

    @Test func restoreWithoutARecordWhenOffChangesNothing() async throws {
        let (core, runner, _, _) = make(sleep: true)
        try await core.restoreOriginalSettings()
        #expect(runner.commands.isEmpty)
    }

    @Test func restoreReleasesHeldFans() async throws {
        let fans = FakeFans()
        let (core, _, _, originals) = make(fans: fans)
        try await core.enable(lowPowerOnBattery: false)
        try await core.setFanPolicy(curve)
        #expect(fans.isHeld)
        try await core.restoreOriginalSettings()
        #expect(!fans.isHeld)
        #expect(originals.saved == nil)
    }

    @Test func restoreKeepsTheRecordWhileFansCannotBeHandedBack() async throws {
        let fans = FakeFans()
        let (core, _, _, originals) = make(fans: fans)
        try await core.enable(lowPowerOnBattery: false)
        try await core.setFanPolicy(curve)
        fans.failRelease()
        await #expect(throws: HelperError.fansStillHeld) { try await core.restoreOriginalSettings() }
        #expect(originals.saved != nil)
        // The next attempt hands the fans back and then finishes.
        fans.failRelease(false)
        try await core.restoreOriginalSettings()
        #expect(!fans.isHeld)
        #expect(originals.saved == nil)
    }
}
