import Foundation
import Testing
@testable import WakeupAppKit

@Suite struct SettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "wakeup-test-\(UUID().uuidString)"
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

    @Test func storeRoundTrips() {
        let store = UserDefaultsSettingsStore(defaults: makeDefaults())
        var s = Settings()
        s.autoLowPowerOnBattery = false
        s.batteryCutoffPercent = 20
        s.thermalCutoff = .critical
        s.launchAtLogin = true
        store.save(s)
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

    @Test func storeClampsOnLoad() {
        let store = UserDefaultsSettingsStore(defaults: makeDefaults())
        var s = Settings()
        s.batteryCutoffPercent = 500
        store.save(s)
        #expect(store.load().batteryCutoffPercent == 50)
    }
}
