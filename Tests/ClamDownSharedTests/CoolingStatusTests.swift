import Foundation
import Testing
import ClamDownShared

@Suite struct CoolingStatusTests {
    @Test func olderStatusWithoutNewFieldsDecodes() throws {
        let old = Data(#"{"cpuTemperature":71.5,"fans":[{"rpm":1300,"minimum":1000,"maximum":5000}],"isControlling":true}"#.utf8)
        let status = try JSONDecoder().decode(CoolingStatus.self, from: old)
        #expect(status.cpuTemperature == 71.5)
        #expect(status.isControlling)
        #expect(status.hottestCPUTemperature == nil)
        #expect(status.override == nil)
        #expect(status.control == .idle)
        #expect(status.systemThermalLevel == nil)
        #expect(status.fans == [FanReading(rpm: 1300, minimum: 1000, maximum: 5000)])
        #expect(status.hottestTemperature == nil)
        #expect(status.hottestGroup == nil)
        #expect(status.groupTemperatures.isEmpty)
    }

    @Test func sensorGroupsRoundTrip() throws {
        let status = CoolingStatus(cpuTemperature: 45, hottestCPUTemperature: 48, fans: [], isControlling: true,
                                   problem: nil, override: .hotBattery, control: .controlling,
                                   hottestTemperature: 52, hottestGroup: .battery,
                                   groupTemperatures: [.cpu: 48, .battery: 52, .wifi: 40])
        let decoded = try JSONDecoder().decode(CoolingStatus.self, from: JSONEncoder().encode(status))
        #expect(decoded == status)
    }

    /// An older app decodes only the fields it knows, so the new ones must not change the old ones' shape.
    @Test func oldFieldsKeepTheirShape() throws {
        let status = CoolingStatus(cpuTemperature: 45, hottestCPUTemperature: 48, fans: [], isControlling: false,
                                   problem: nil, hottestTemperature: 52, hottestGroup: .battery,
                                   groupTemperatures: [.battery: 52])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any]
        #expect(object?["cpuTemperature"] as? Double == 45)
        #expect(object?["hottestCPUTemperature"] as? Double == 48)
        #expect(object?["isControlling"] as? Bool == false)
        #expect(object?["groupTemperatures"] as? [String: Double] == ["battery": 52])
    }

    @Test func unknownGroupsFromALaterHelperAreDropped() throws {
        let later = Data(#"{"fans":[],"isControlling":false,"hottestTemperature":61,"hottestGroup":"enclosure","groupTemperatures":{"cpu":50,"enclosure":61}}"#.utf8)
        let status = try JSONDecoder().decode(CoolingStatus.self, from: later)
        #expect(status.hottestTemperature == 61)
        #expect(status.hottestGroup == nil)
        #expect(status.groupTemperatures == [.cpu: 50])
    }

    @Test func newFieldsRoundTrip() throws {
        let status = CoolingStatus(cpuTemperature: 80, hottestCPUTemperature: 99, fans: [], isControlling: true,
                                   problem: nil, override: .hotCore, control: .controlling, systemThermalLevel: .serious)
        let decoded = try JSONDecoder().decode(CoolingStatus.self, from: JSONEncoder().encode(status))
        #expect(decoded == status)
    }

    /// A later build may add states; an older app shows what it can instead of nothing.
    @Test func unknownValuesFromALaterHelperDecodeAsUnknown() throws {
        let later = Data(#"{"fans":[],"isControlling":false,"override":"battery","control":"paused","systemThermalLevel":9}"#.utf8)
        let status = try JSONDecoder().decode(CoolingStatus.self, from: later)
        #expect(status.override == nil)
        #expect(status.control == .idle)
        #expect(status.systemThermalLevel == nil)
    }
}
