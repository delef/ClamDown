import Testing
@testable import WakeupAppKit

@Suite struct AutoOffPolicyTests {
    /// Builds a snapshot and default settings (battery cut-off 10, thermal cut-off `.serious`) and asks the policy.
    private func reason(
        pct: Int? = 50,
        onBattery: Bool = true,
        thermal: ThermalLevel = .nominal,
        cutoff: ThermalCutoff = .serious
    ) -> AutoOffReason? {
        var settings = Settings()
        settings.thermalCutoff = cutoff
        let snapshot = SystemSnapshot(batteryPercent: pct, isOnBattery: onBattery, thermal: thermal)
        return AutoOffPolicy.reason(for: snapshot, settings: settings)
    }

    @Test func batteryAtCutoffOnBatteryTriggers() {
        #expect(reason(pct: 10, onBattery: true) == .batteryLow(percent: 10))
    }

    @Test func batteryAboveCutoffIsFine() {
        #expect(reason(pct: 11, onBattery: true) == nil)
    }

    @Test func lowBatteryWhileChargingIsFine() {
        #expect(reason(pct: 5, onBattery: false) == nil)
    }

    @Test func noBatteryNeverTriggersBatteryRule() {
        #expect(reason(pct: nil, onBattery: false) == nil)
        #expect(reason(pct: nil, onBattery: true) == nil)
    }

    @Test func thermalAtCutoffTriggers() {
        #expect(reason(thermal: .serious) == .thermal(.serious))
    }

    @Test func thermalBelowCutoffIsFine() {
        #expect(reason(thermal: .fair) == nil)
    }

    @Test func thermalNeverIgnoresCritical() {
        #expect(reason(thermal: .critical, cutoff: .never) == nil)
    }

    @Test func thermalWinsWhenBothTrigger() {
        #expect(reason(pct: 5, onBattery: true, thermal: .critical) == .thermal(.critical))
    }

    @Test func summaryTexts() {
        #expect(AutoOffReason.batteryLow(percent: 10).summary == "battery at 10%")
        #expect(AutoOffReason.thermal(.serious).summary == "Mac is hot (serious)")
    }
}
