import Foundation
import Testing
import ClamDownShared
@testable import ClamDownSensors

/// Replays SMC key dumps taken from real Macs (`ClamDownFanProbe keys <machine>`), so key discovery and decoding
/// are checked against real data. Add a dump from each new Mac or macOS version.
@Suite struct KeyDumpTests {
    static let dumps = ["m3-pro-macos-27"]

    @Test(arguments: dumps) func everyGroupIsFoundAndPlausible(name: String) throws {
        let dump = try FakeSMC.fixture(name)
        let reading = try SMCFanHardware(smc: FakeSMC(dump: dump), pause: { _ in }, lidClosed: { true }).read()
        #expect(Set(reading.groupTemperatures.keys) == Set(SensorGroup.allCases), "\(dump.machine)")
        for (group, celsius) in reading.groupTemperatures {
            #expect((15...110).contains(celsius), "\(group) at \(celsius) °C on \(dump.machine)")
        }
        let average = try #require(reading.cpuTemperature)
        let hottest = try #require(reading.hottestCPUTemperature)
        #expect(average <= hottest)
    }

    @Test(arguments: dumps) func fansAreControllableWithSaneRanges(name: String) throws {
        let dump = try FakeSMC.fixture(name)
        let hardware = SMCFanHardware(smc: FakeSMC(dump: dump), pause: { _ in }, lidClosed: { true })
        #expect(hardware.supportsControl)
        let fans = try hardware.read().fans
        #expect(fans.count == hardware.fanCount && hardware.fanCount > 0)
        for fan in fans {
            #expect(fan.minimum > 0 && fan.minimum < fan.maximum && fan.maximum < 10_000)
        }
    }

    @Test(arguments: dumps) func batteryTemperatureComesFromTheSMC(name: String) throws {
        let dump = try FakeSMC.fixture(name)
        let celsius = try #require(SMCBatteryTemperature(smc: FakeSMC(dump: dump))?.read())
        #expect((15...60).contains(celsius))
    }

    @Test func noBatteryKeysMeansNoReader() {
        #expect(SMCBatteryTemperature(smc: FakeSMC([("TaLP", .float(40))])) == nil)
    }

    @Test(arguments: dumps) func dumpKeepsOnlyTemperatureAndFanKeys(name: String) throws {
        let dump = try FakeSMC.fixture(name)
        #expect(dump.entries.allSatisfy { SMCKeyDump.isKept($0.key) })
        #expect(dump.entries.allSatisfy { $0.value != nil })
    }
}
