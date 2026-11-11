import Testing
@testable import ClamDownAppKit

@Suite struct PowerSnapshotMapperTests {
    private func bat(_ current: Int, _ maximum: Int) -> [String: Any] {
        ["Type": "InternalBattery", "Current Capacity": current, "Max Capacity": maximum]
    }

    private func map(_ source: String?, _ descriptions: [[String: Any]]) -> (batteryPercent: Int?, isOnBattery: Bool) {
        PowerSnapshotMapper.map(providingSource: source, descriptions: descriptions)
    }

    @Test func batteryPowerWithPercent() {
        #expect(map("Battery Power", [bat(42, 100)]) == (42, true))
    }

    @Test func acPowerKeepsPercent() {
        #expect(map("AC Power", [bat(80, 100)]) == (80, false))
    }

    @Test func scalesNonPercentCapacities() {
        #expect(map("Battery Power", [bat(4200, 10000)]) == (42, true))
    }

    @Test func noBatteryDescriptors() {
        #expect(map("AC Power", []) == (nil, false))
    }

    @Test func ignoresNonInternalSources() {
        #expect(map("AC Power", [["Type": "UPS", "Current Capacity": 50, "Max Capacity": 100]]) == (nil, false))
    }

    @Test func zeroMaxCapacityGivesNoPercent() {
        #expect(map("Battery Power", [bat(0, 0)]) == (nil, true))
    }

    @Test func unknownProvidingSourceIsNotOnBattery() {
        #expect(map(nil, [bat(50, 100)]) == (50, false))
        #expect(map("UPS Power", [bat(50, 100)]) == (50, false))
    }
}
