import Foundation
import Testing
@testable import ClamDownAppKit
import ClamDownShared
import ClamDownSensors

@Suite struct BatteryHeatWatchTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0 + seconds }

    private func snapshot(_ celsius: Double?) -> SystemSnapshot {
        SystemSnapshot(batteryPercent: 80, isOnBattery: true, thermal: .nominal, batteryTemperature: celsius)
    }

    @Test func firesOnlyAfterTheHold() {
        var watch = BatteryHeatWatch()
        let settings = Settings()  // 55 °C for 60 s
        #expect(watch.update(snapshot(55), settings: settings, now: at(0)) == nil)
        #expect(watch.update(snapshot(56), settings: settings, now: at(59)) == nil)
        #expect(watch.update(snapshot(56.4), settings: settings, now: at(60)) == .batteryHot(celsius: 56))
    }

    @Test func aDipBelowTheLimitStartsTheHoldAgain() {
        var watch = BatteryHeatWatch()
        let settings = Settings()
        _ = watch.update(snapshot(57), settings: settings, now: at(0))
        #expect(watch.update(snapshot(54.9), settings: settings, now: at(30)) == nil)
        #expect(watch.update(snapshot(57), settings: settings, now: at(40)) == nil)
        #expect(watch.update(snapshot(57), settings: settings, now: at(99)) == nil)
        #expect(watch.update(snapshot(57), settings: settings, now: at(100)) == .batteryHot(celsius: 57))
    }

    @Test func noTemperatureNeverFires() {
        var watch = BatteryHeatWatch()
        for second in stride(from: 0.0, through: 600, by: 30) {
            #expect(watch.update(snapshot(nil), settings: Settings(), now: at(second)) == nil)
        }
    }

    @Test func aMissingReadingStartsTheHoldAgain() {
        var watch = BatteryHeatWatch()
        _ = watch.update(snapshot(58), settings: Settings(), now: at(0))
        _ = watch.update(snapshot(nil), settings: Settings(), now: at(30))
        #expect(watch.update(snapshot(58), settings: Settings(), now: at(60)) == nil)
    }

    @Test func settingOffNeverFires() {
        var watch = BatteryHeatWatch()
        var settings = Settings()
        settings.batteryHeatCutoffEnabled = false
        for second in stride(from: 0.0, through: 600, by: 30) {
            #expect(watch.update(snapshot(60), settings: settings, now: at(second)) == nil)
        }
    }

    @Test func limitAndHoldComeFromTheSettings() {
        var watch = BatteryHeatWatch()
        var settings = Settings()
        settings.batteryHeatLimit = 50
        settings.batteryHeatHold = .seconds30
        #expect(watch.update(snapshot(50), settings: settings, now: at(0)) == nil)
        #expect(watch.update(snapshot(50), settings: settings, now: at(30)) == .batteryHot(celsius: 50))
    }

    @Test func resetForgetsTheHold() {
        var watch = BatteryHeatWatch()
        _ = watch.update(snapshot(58), settings: Settings(), now: at(0))
        watch.reset()
        #expect(watch.update(snapshot(58), settings: Settings(), now: at(60)) == nil)
    }
}

@Suite struct BatteryHeatPolicyTests {
    private let hot = AutoOffReason.batteryHot(celsius: 56)

    @Test func itIsProtectiveAndSaysWhy() {
        #expect(hot.isProtective)
        #expect(hot.summary == "battery is hot (56 °C)")
    }

    @Test func thermalComesFirst() {
        let snapshot = SystemSnapshot(batteryPercent: 80, isOnBattery: true, thermal: .serious, batteryTemperature: 56)
        #expect(AutoOffPolicy.reason(for: snapshot, settings: Settings(), batteryHeat: hot) == .thermal(.serious))
    }

    @Test func hotBatteryComesBeforeUnpluggedAndLowBattery() {
        var settings = Settings()
        settings.turnOffWhenUnplugged = true
        let snapshot = SystemSnapshot(batteryPercent: 5, isOnBattery: true, thermal: .nominal, batteryTemperature: 56)
        #expect(AutoOffPolicy.reason(for: snapshot, settings: settings, batteryHeat: hot) == hot)
        #expect(AutoOffPolicy.reason(for: snapshot, settings: settings) == .unplugged)
    }
}

@Suite struct BatteryHeatSettingsTests {
    @Test func defaults() {
        let s = Settings()
        #expect(s.batteryHeatCutoffEnabled && s.batteryHeatLimit == 55 && s.batteryHeatHold == .minute1)
        #expect(s.batteryHeatHold.duration == 60)
        #expect(BatteryHeatHold.allCases.map(\.rawValue) == [30, 60, 120, 300])
        #expect(BatteryHeatHold.allCases.map(\.title) == ["30 seconds", "1 minute", "2 minutes", "5 minutes"])
    }

    @Test func limitIsClampedToItsRange() {
        var s = Settings()
        s.batteryHeatLimit = 40
        #expect(s.clamped().batteryHeatLimit == 50)
        s.batteryHeatLimit = 70
        #expect(s.clamped().batteryHeatLimit == 60)
    }

    @Test func roundTripsAndOldFilesGetTheDefaults() throws {
        var s = Settings()
        s.batteryHeatCutoffEnabled = false
        s.batteryHeatLimit = 58
        s.batteryHeatHold = .minutes5
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)) == s)
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"batteryCutoffPercent":20,"batteryHeatHold":7}"#.utf8))
        #expect(old.batteryHeatCutoffEnabled && old.batteryHeatLimit == 55 && old.batteryHeatHold == .minute1)
    }

    @Test func temperatureFromHundredths() {
        #expect(PowerSnapshotMapper.batteryCelsius(hundredths: 3125) == 31.25)
        #expect(PowerSnapshotMapper.batteryCelsius(hundredths: nil) == nil)
        #expect(PowerSnapshotMapper.batteryCelsius(hundredths: 0) == nil)
    }
}

@MainActor @Suite struct ClamDownControllerBatteryHeatTests {
    private static let unattended = LidState(closed: true, closingCausesSleep: true)

    private func hot(_ celsius: Double?) -> SystemSnapshot {
        SystemSnapshot(batteryPercent: 80, isOnBattery: true, thermal: .nominal, batteryTemperature: celsius)
    }

    @Test func hotBatteryForTheHoldSwitchesOffAndSleeps() async {
        let rig = Rig(lidState: Self.unattended)
        await rig.controller.toggle()
        rig.monitor.current = hot(56)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .on)
        rig.clock.advance(by: 30)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .on)
        rig.clock.advance(by: 30)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.sleeper.sleepCount == 1)
        #expect(rig.controller.notice == "Turned off: battery is hot (56 °C). The Mac is going to sleep.")
    }

    @Test func aDipResetsTheHold() async {
        let rig = Rig(lidState: Self.unattended)
        await rig.controller.toggle()
        rig.monitor.current = hot(56)
        await rig.controller.handleSystemChange()
        rig.clock.advance(by: 50)
        rig.monitor.current = hot(50)
        await rig.controller.handleSystemChange()
        rig.monitor.current = hot(56)
        rig.clock.advance(by: 20)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .on)
    }

    /// The hold starts at Turn On: a Mac whose battery is already hot runs for the hold time, then sleeps.
    @Test func turnOnWithAHotBatteryStartsTheHold() async {
        let rig = Rig(snapshot: hot(57), lidState: Self.unattended)
        await rig.controller.toggle()
        #expect(rig.controller.state == .on)
        rig.clock.advance(by: 60)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
    }

    @Test func aNewTurnOnStartsTheHoldAgain() async {
        let rig = Rig(snapshot: hot(57), lidState: LidState(closed: false, closingCausesSleep: true))
        await rig.controller.toggle()
        rig.clock.advance(by: 50)
        await rig.controller.handleSystemChange()
        await rig.controller.toggle()
        await rig.controller.toggle()
        rig.clock.advance(by: 20)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .on)
    }
}
