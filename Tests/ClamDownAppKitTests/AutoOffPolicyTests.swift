import Testing
@testable import ClamDownAppKit
import ClamDownShared

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

    @Test func reasonTexts() {
        #expect(AutoOffReason.batteryLow(percent: 10).turnedOffText == "Turned off because the battery is at 10%.")
        #expect(AutoOffReason.thermal(.serious).notTurnedOnText == "Not turned on because the Mac is hot (Serious).")
        #expect(AutoOffReason.batteryHot(celsius: 56).pastText == "The battery was hot (56 \u{00B0}C).")
    }

    /// Every reason text is a whole sentence, so it never needs another sentence's grammar in a translation.
    @Test(arguments: [AutoOffReason.batteryLow(percent: 10), .thermal(.critical), .batteryHot(celsius: 56),
                      .unplugged, .timerEnded])
    func everyReasonTextIsAWholeSentence(reason: AutoOffReason) {
        for text in [reason.turnedOffText, reason.notTurnedOnText, reason.pastText] {
            #expect(text.first?.isUppercase == true, "\(text)")
            #expect(text.hasSuffix("."), "\(text)")
        }
    }
}

@Suite struct AutoOffPolicyFeatureTests {
    @Test func unpluggedWinsOverBatteryLevelWhenEnabled() {
        var settings = Settings()
        settings.turnOffWhenUnplugged = true
        let snapshot = SystemSnapshot(batteryPercent: 5, isOnBattery: true, thermal: .nominal)
        #expect(AutoOffPolicy.reason(for: snapshot, settings: settings) == .unplugged)
    }

    @Test func pluggedInIsFineWhenUnpluggedCutoffIsOn() {
        var settings = Settings()
        settings.turnOffWhenUnplugged = true
        let snapshot = SystemSnapshot(batteryPercent: 80, isOnBattery: false, thermal: .nominal)
        #expect(AutoOffPolicy.reason(for: snapshot, settings: settings) == nil)
    }

    @Test func disabledBatteryCutoffIgnoresLowCharge() {
        var settings = Settings()
        settings.batteryCutoffEnabled = false
        let snapshot = SystemSnapshot(batteryPercent: 5, isOnBattery: true, thermal: .nominal)
        #expect(AutoOffPolicy.reason(for: snapshot, settings: settings) == nil)
    }

    @Test func thermalStillAppliesWithEverythingElseOff() {
        var settings = Settings()
        settings.batteryCutoffEnabled = false
        let snapshot = SystemSnapshot(batteryPercent: 50, isOnBattery: true, thermal: .critical)
        #expect(AutoOffPolicy.reason(for: snapshot, settings: settings) == .thermal(.critical))
    }
}

@Suite struct ThermalLevelNameTests {
    @Test func levelFromItsName() {
        #expect(ThermalLevel(name: "serious") == .serious)
        #expect(ThermalLevel(name: "nominal") == .nominal)
        #expect(ThermalLevel(name: "hot") == nil)
    }
}
