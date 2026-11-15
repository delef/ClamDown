import Foundation
import Testing
@testable import ClamDownAppKit
import ClamDownShared

@Suite struct SettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "clamdown-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsMatchSpec() {
        let s = Settings()
        #expect(s.autoLowPowerOnBattery && s.batteryCutoffPercent == 10 && s.thermalCutoff == .serious && !s.launchAtLogin)
    }

    @Test func clampsBatteryCutoff() {
        var s = Settings()
        s.batteryCutoffPercent = 500
        #expect(s.clamped().batteryCutoffPercent == 50)
        s.batteryCutoffPercent = -3
        #expect(s.clamped().batteryCutoffPercent == 5)
    }

    @Test func thermalLevelsOrdered() {
        #expect(ThermalLevel.fair < ThermalLevel.serious && ThermalLevel.serious < ThermalLevel.critical)
        #expect(ThermalLevel.nominal < ThermalLevel.fair)
    }

    @Test func mapsProcessInfoThermalStates() {
        #expect(ThermalLevel(.nominal) == .nominal)
        #expect(ThermalLevel(.fair) == .fair)
        #expect(ThermalLevel(.serious) == .serious)
        #expect(ThermalLevel(.critical) == .critical)
    }

    @Test func neverHasNoLevel() {
        #expect(ThermalCutoff.never.level == nil && ThermalCutoff.serious.level == .serious)
        #expect(ThermalCutoff.fair.level == .fair && ThermalCutoff.critical.level == .critical)
    }

    @Test func storeRoundTrips() throws {
        let store = UserDefaultsSettingsStore(defaults: makeDefaults())
        var s = Settings()
        s.autoLowPowerOnBattery = false
        s.batteryCutoffPercent = 20
        s.thermalCutoff = .critical
        s.launchAtLogin = true
        try store.save(s)
        #expect(store.load() == s)
    }

    @Test func storeReturnsDefaultsWhenEmpty() {
        #expect(UserDefaultsSettingsStore(defaults: makeDefaults()).load() == Settings())
    }

    @Test func storeReturnsDefaultsWhenCorrupt() {
        let defaults = makeDefaults()
        defaults.set(Data("garbage".utf8), forKey: "settings.v1")
        #expect(UserDefaultsSettingsStore(defaults: defaults).load() == Settings())
    }

    @Test func storeClampsOnLoad() throws {
        let store = UserDefaultsSettingsStore(defaults: makeDefaults())
        var s = Settings()
        s.batteryCutoffPercent = 500
        try store.save(s)
        #expect(store.load().batteryCutoffPercent == 50)
    }
}

@Suite struct SettingsMigrationTests {
    @Test func settingsFromAnOlderBuildKeepTheirValuesAndGetNewDefaults() throws {
        let old = #"{"autoLowPowerOnBattery":false,"batteryCutoffPercent":20,"thermalCutoff":"critical","launchAtLogin":true}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(!s.autoLowPowerOnBattery && s.batteryCutoffPercent == 20 && s.thermalCutoff == .critical && s.launchAtLogin)
        #expect(s.lockScreenWhenLidClosed && s.batteryCutoffEnabled && s.autoOffTimer == .never && s.menuBarIcon == .lid)
    }

    @Test func anUnknownValueFallsBackToItsDefault() throws {
        let json = #"{"menuBarIcon":"rocket","batteryCutoffPercent":25}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.menuBarIcon == .lid && s.batteryCutoffPercent == 25)
    }

    @Test func lidIsTheDefaultIcon() { #expect(Settings().menuBarIcon == .lid) }

    @Test func storedStyleIsKept() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"menuBarIcon":"bolt"}"#.utf8))
        #expect(s.menuBarIcon == .bolt)
    }

    @Test func timerDurations() {
        #expect(AutoOffTimer.never.duration == nil)
        #expect(AutoOffTimer.hour1.duration == .seconds(3600))
        #expect(AutoOffTimer.hours8.duration == .seconds(8 * 3600))
    }

    @Test func iconSymbols() {
        #expect(MenuBarIconStyle.cup.offSymbol == "cup.and.saucer" && MenuBarIconStyle.cup.onSymbol == "cup.and.saucer.fill")
        #expect(MenuBarIconStyle.bolt.onSymbol == "bolt.fill")
    }

    @Test func lidSymbolNames() {
        #expect(MenuBarIconStyle.lid.offSymbol == "clamdown.lid" && MenuBarIconStyle.lid.onSymbol == "clamdown.lid.fill")
        #expect(MenuBarIconStyle.lid.title == "Lid")
        #expect(MenuBarIconStyle.lid.isDrawn && !MenuBarIconStyle.cup.isDrawn)
        #expect(MenuBarIconStyle.allCases.first == .lid)
    }
}

@Suite struct FanSettingsTests {
    private let standardLine = [FanPoint(temperature: 40, speed: 0), FanPoint(temperature: 70, speed: 100)]

    @Test func defaultsDriveTheFansOnlyWithTheLidClosed() {
        let s = Settings()
        #expect(s.fanControlEnabled && s.fanCurveMode == .standard && s.fanAdvancedPoints == nil && s.fansOnlyWhenLidClosed)
        #expect(s.fanPolicy == FanPolicy(points: standardLine, onlyWhenLidClosed: true, caseRamp: .standard))
    }

    /// A Mac in a bag has little airflow, so the fans start before anything is hot.
    @Test func fanCurveStartsEarlierByDefault() {
        #expect(Settings().fanStartTemperature == 40)
        #expect(Settings().fanFullSpeedTemperature == 70)
    }

    @Test func sleepAfterProtectionDefaultsOnAlsoForOldSettings() throws {
        #expect(Settings().sleepAfterProtection)
        let old = Data(#"{"batteryCutoffPercent":20}"#.utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: old).sleepAfterProtection)
        var off = Settings()
        off.sleepAfterProtection = false
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(off)).sleepAfterProtection == false)
    }

    @Test func clampingKeepsTheCurveValid() {
        var s = Settings()
        s.fanStartTemperature = 88
        s.fanFullSpeedTemperature = 70
        let clamped = s.clamped()
        #expect(clamped.fanStartTemperature == 70 && clamped.fanFullSpeedTemperature == 75)
    }

    @Test func clampingRepairsTheAdvancedPoints() {
        var s = Settings()
        s.fanAdvancedPoints = [.init(temperature: 30, speed: 50), .init(temperature: 60, speed: 20), .init(temperature: 65, speed: 60),
                               .init(temperature: 70, speed: 70), .init(temperature: 80, speed: 100)]
        #expect(s.clamped().fanAdvancedPoints == [.init(temperature: 40, speed: 50), .init(temperature: 60, speed: 50),
                                                  .init(temperature: 65, speed: 60), .init(temperature: 70, speed: 70),
                                                  .init(temperature: 80, speed: 100)])
    }

    /// Corrupt or hand-edited points must never switch the fans off while the switch shows On.
    @Test func emptyAdvancedPointsFallBackToDefault() throws {
        let json = #"{"fanControlEnabled":true,"fanCurveMode":"advanced","fanAdvancedPoints":[]}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.fanAdvancedPoints == nil)
        #expect(s.fanPolicy.points == FanCurveEditor.defaultAdvanced)
        var direct = Settings()
        direct.fanCurveMode = .advanced
        direct.fanAdvancedPoints = []
        #expect(!direct.fanPolicy.isOff && direct.fanPolicy.points == FanCurveEditor.defaultAdvanced)
        #expect(direct.clamped().fanAdvancedPoints == nil)
    }

    @Test func wrongCountAdvancedPointsFallBackToDefault() throws {
        let json = #"{"fanControlEnabled":true,"fanCurveMode":"advanced","fanAdvancedPoints":[{"temperature":60,"speed":10},{"temperature":70,"speed":20},{"temperature":80,"speed":90}]}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.fanAdvancedPoints == nil)
        #expect(!s.fanPolicy.isOff && s.fanPolicy.points == FanCurveEditor.defaultAdvanced)
        var six = Settings()
        six.fanCurveMode = .advanced
        six.fanAdvancedPoints = FanCurveEditor.defaultAdvanced + [FanPoint(temperature: 90, speed: 100)]
        #expect(six.fanPolicy.points == FanCurveEditor.defaultAdvanced)
        // Choosing Advanced again copies the Standard line instead of keeping the broken list.
        six.fanCurveMode = .standard
        six.fanStartTemperature = 60
        six.fanFullSpeedTemperature = 80
        #expect(FanCurveEditor.chooseAdvanced(six).fanAdvancedPoints == FanCurveEditor.advanced(fromStart: 60, full: 80))
    }

    @Test func settingsFromBeforeFanControlGetTheDefaults() throws {
        let old = Data(#"{"batteryCutoffPercent":20,"thermalCutoff":"fair"}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: old)
        #expect(s.batteryCutoffPercent == 20 && s.fanControlEnabled && s.fanCurveMode == .standard && s.fanFullSpeedTemperature == 70)
    }

    @Test func fanSettingsRoundTrip() throws {
        var s = Settings()
        s.fanControlEnabled = false
        s.fanCurveMode = .advanced
        s.fanAdvancedPoints = FanCurveEditor.defaultAdvanced
        s.fansOnlyWhenLidClosed = false
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
    }

    @Test func policyFollowsSettings() {
        var s = Settings()
        s.fanControlEnabled = false
        #expect(s.fanPolicy.points == [])
        s.fanControlEnabled = true
        #expect(s.fanPolicy.points == standardLine)
        s.fanCurveMode = .advanced
        #expect(s.fanPolicy.points == FanCurveEditor.defaultAdvanced)
        let own = [FanPoint(temperature: 45, speed: 10), FanPoint(temperature: 55, speed: 20), FanPoint(temperature: 65, speed: 30),
                   FanPoint(temperature: 75, speed: 40), FanPoint(temperature: 85, speed: 80)]
        s.fanAdvancedPoints = own
        #expect(s.fanPolicy == FanPolicy(points: own, onlyWhenLidClosed: true, caseRamp: .standard))
        s.fanCurveMode = .standard
        #expect(s.fanPolicy.points == standardLine)
    }

    @Test func caseRuleDefaultsTo38And44AndGoesToTheHelper() {
        let s = Settings()
        #expect(s.caseStartTemperature == 38 && s.caseFullSpeedTemperature == 44)
        #expect(s.fanPolicy.caseRamp == CaseRamp(start: 38, full: 44))
    }

    @Test func caseRuleFromAnOlderBuildGetsTheDefaults() throws {
        let old = Data(#"{"fanControlEnabled":true,"fanStartTemperature":45}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: old)
        #expect(s.fanStartTemperature == 45 && s.caseRamp == .standard)
    }

    @Test func caseRuleRoundTripsAndClamps() throws {
        var s = Settings()
        s.caseStartTemperature = 41
        s.caseFullSpeedTemperature = 48
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)) == s)
        s.caseStartTemperature = 49
        s.caseFullSpeedTemperature = 40
        let clamped = s.clamped()
        #expect(clamped.caseStartTemperature == 49 && clamped.caseFullSpeedTemperature == 51)
        s.caseStartTemperature = 10
        s.caseFullSpeedTemperature = 99
        #expect(s.clamped().caseRamp == CaseRamp(start: 30, full: 60))
    }
}

/// Builds up to 0.1.2 stored one `fanMode`; the switch and the two curves replace it.
@Suite struct FanModeMigrationTests {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test func oldCurveBecomesStandard() throws {
        let s = try decode(#"{"fanMode":"curve","fanStartTemperature":55,"fanFullSpeedTemperature":80}"#)
        #expect(s.fanControlEnabled && s.fanCurveMode == .standard)
        #expect(s.fanStartTemperature == 55 && s.fanFullSpeedTemperature == 80)
        #expect(s.fanAdvancedPoints == nil)
    }

    @Test func oldSystemTurnsFanControlOff() throws {
        let s = try decode(#"{"fanMode":"system"}"#)
        #expect(!s.fanControlEnabled)
        #expect(s.fanPolicy.isOff)
    }

    @Test func oldFullSpeedBecomesAdvancedAtFull() throws {
        let s = try decode(#"{"fanMode":"fullSpeed"}"#)
        #expect(s.fanControlEnabled && s.fanCurveMode == .advanced)
        #expect(s.fanAdvancedPoints == [40, 50, 60, 70, 80].map { FanPoint(temperature: $0, speed: 100) })
    }

    @Test func fileWithoutFanKeysGetsDefaults() throws {
        let s = try decode("{}")
        #expect(s.fanControlEnabled && s.fanCurveMode == .standard)
        #expect(s.fanStartTemperature == 40 && s.fanFullSpeedTemperature == 70)
    }

    @Test func newerKeysWinOverOldFanMode() throws {
        #expect(try decode(#"{"fanMode":"system","fanControlEnabled":true}"#).fanControlEnabled)
        let s = try decode(#"{"fanMode":"fullSpeed","fanControlEnabled":true,"fanCurveMode":"standard"}"#)
        #expect(s.fanCurveMode == .standard && s.fanAdvancedPoints == nil)
    }

    @Test func laterChangeIsKept() throws {
        var s = try decode(#"{"fanMode":"curve"}"#)
        s.fanCurveMode = .advanced
        let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(again.fanCurveMode == .advanced)
        #expect(!String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("fanMode"))
    }

    @Test func standardOutsideNewRangesMoves() throws {
        let s = try decode(#"{"fanMode":"curve","fanStartTemperature":85,"fanFullSpeedTemperature":100}"#).clamped()
        #expect(s.fanStartTemperature == 70 && s.fanFullSpeedTemperature == 95)
    }

    @Test func storeMigratesAnOldFileTogetherWithTheOldDefaults() throws {
        let suite = "clamdown.tests.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = #"{"fanMode":"curve","fanStartTemperature":60,"fanFullSpeedTemperature":85,"batteryCutoffPercent":20}"#
        defaults.set(Data(old.utf8), forKey: "settings.v1")
        let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
        #expect(loaded.fanControlEnabled && loaded.fanCurveMode == .standard && loaded.batteryCutoffPercent == 20)
        #expect(loaded.fanStartTemperature == 40 && loaded.fanFullSpeedTemperature == 70)
    }
}

@Suite struct FanDefaultsMigrationTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "clamdown.tests.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func stored(start: Int, full: Int) -> Settings {
        var settings = Settings()
        settings.fanStartTemperature = start
        settings.fanFullSpeedTemperature = full
        return settings
    }

    /// Settings saved by 0.1.0 and 0.1.1 hold every value, so the old defaults would otherwise stay forever.
    @Test func oldFanDefaultsMoveOnce() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(stored(start: 60, full: 85)), forKey: "settings.v1")
            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded.fanStartTemperature == 40 && loaded.fanFullSpeedTemperature == 70)
            // Saved, not only returned: the next launch reads the new values without the migration.
            #expect(UserDefaultsSettingsStore(defaults: defaults).load().fanStartTemperature == 40)
        }
    }

    /// 0.1.2's defaults were 50 and 75; the curve now follows the hottest sensor and starts at 40.
    @Test func fanDefaultsOf50And75MoveOnce() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(stored(start: 50, full: 75)), forKey: "settings.v1")
            defaults.set(true, forKey: "settings.fanCurveDefaults.v2")
            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded.fanStartTemperature == 40 && loaded.fanFullSpeedTemperature == 70)
            #expect(UserDefaultsSettingsStore(defaults: defaults).load().fanFullSpeedTemperature == 70)
        }
    }

    @Test func ownStandardValuesStay() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(stored(start: 55, full: 80)), forKey: "settings.v1")
            defaults.set(true, forKey: "settings.fanCurveDefaults.v2")
            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded.fanStartTemperature == 55 && loaded.fanFullSpeedTemperature == 80)
        }
    }

    @Test func fileWithoutTheFanKeysGetsTheNewDefaults() throws {
        try withDefaults { defaults in
            defaults.set(Data(#"{"batteryCutoffPercent":15}"#.utf8), forKey: "settings.v1")
            defaults.set(true, forKey: "settings.fanCurveDefaults.v2")
            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded.fanStartTemperature == 40 && loaded.fanFullSpeedTemperature == 70)
            #expect(loaded.batteryCutoffPercent == 15)
        }
    }

    /// Once migrated, 50 and 75 chosen on purpose are the user's own values.
    @Test func alreadyMigratedFileIsLeftAlone() throws {
        try withDefaults { defaults in
            let store = UserDefaultsSettingsStore(defaults: defaults)
            defaults.set(try JSONEncoder().encode(stored(start: 50, full: 75)), forKey: "settings.v1")
            #expect(store.load().fanStartTemperature == 40)
            try store.save(stored(start: 50, full: 75))
            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded.fanStartTemperature == 50 && loaded.fanFullSpeedTemperature == 75)
        }
    }

    @Test func advancedPointsAreNotTouched() throws {
        try withDefaults { defaults in
            var settings = stored(start: 50, full: 75)
            settings.fanCurveMode = .advanced
            let own = FanCurveEditor.advanced(fromStart: 50, full: 75)
            settings.fanAdvancedPoints = own
            defaults.set(try JSONEncoder().encode(settings), forKey: "settings.v1")
            defaults.set(true, forKey: "settings.fanCurveDefaults.v2")
            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded.fanAdvancedPoints == own && loaded.fanCurveMode == .advanced)
            #expect(loaded.fanStartTemperature == 40 && loaded.fanFullSpeedTemperature == 70)
        }
    }

    @Test func otherFanValuesStay() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(stored(start: 65, full: 85)), forKey: "settings.v1")
            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded.fanStartTemperature == 65 && loaded.fanFullSpeedTemperature == 85)
        }
    }

    @Test func deliberateOldValuesStayAfterMigration() throws {
        try withDefaults { defaults in
            let store = UserDefaultsSettingsStore(defaults: defaults)
            _ = store.load()
            try store.save(stored(start: 60, full: 85))
            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded.fanStartTemperature == 60 && loaded.fanFullSpeedTemperature == 85)
        }
    }
}
