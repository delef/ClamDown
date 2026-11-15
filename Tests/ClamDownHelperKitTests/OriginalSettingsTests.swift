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
        fans: FakeFans? = nil
    ) -> (HelperCore, FakeRunner, FakeStore, FakeOriginalStore) {
        let runner = FakeRunner(batteryLowPower: prior, sleepDisabled: sleep)
        let store = FakeStore()
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

    @Test func laterEnablesNeverReplaceTheRecord() async throws {
        let (core, _, _, originals) = make()
        try await core.enable(lowPowerOnBattery: false)
        try await core.disable()
        try await core.enable(lowPowerOnBattery: true)
        #expect(originals.saveCount == 1)
    }

    @Test func anExistingRecordIsKeptEvenWhenTheCurrentValuesDiffer() async throws {
        let earlier = recorded(sleep: true, lowPower: true)
        let (core, _, _, originals) = make(prior: false, sleep: false, original: earlier)
        try await core.enable(lowPowerOnBattery: true)
        #expect(originals.saved == earlier)
        #expect(originals.saveCount == 0)
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
        originals.failLoad()
        try await core.restoreOriginalSettings()
        #expect(runner.commands.contains(.setSleepDisabled(false)))
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

    @Test func restoreWithoutARecordWhenOffOnlyResetsSleep() async throws {
        let (core, runner, _, _) = make()
        try await core.restoreOriginalSettings()
        #expect(runner.commands == [.setSleepDisabled(false)])
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
