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
