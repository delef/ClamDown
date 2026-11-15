import Foundation
import Testing
import ClamDownShared
@testable import ClamDownSensors

/// The order of SMC writes for each fan operation. A wrong order can leave a fan with no one driving it.
@Suite struct SMCFanHardwareTests {
    /// Two fans with macOS in control, two CPU cores, one GPU sensor, battery and airflow.
    private func smc(fanModes: [UInt8] = [0, 0]) -> FakeSMC {
        var values: [(String, SMCValue)] = [("FNum", .byte(UInt8(fanModes.count))), ("Ftst", .byte(0))]
        for (index, mode) in fanModes.enumerated() {
            values += [("F\(index)Ac", .float(1200)), ("F\(index)Mn", .float(1000)), ("F\(index)Mx", .float(5000)),
                       ("F\(index)Md", .byte(mode)), ("F\(index)Tg", .float(1000))]
        }
        values += [("Tp01", .float(50)), ("Te02", .float(60)), ("Tg05", .float(55)), ("TB0T", .float(37)),
                   ("TaLP", .float(40)), ("TaRF", .float(41.5)), ("TZ99", .float(200))]
        return FakeSMC(values)
    }

    private func hardware(_ smc: FakeSMC, lid: Bool? = true) -> SMCFanHardware {
        SMCFanHardware(smc: smc, takeoverTimeout: .zero, pause: { _ in }, lidClosed: { lid })
    }

    private func target(_ rpm: Float) -> [UInt8] { SMCValue.float(rpm).bytes }

    @Test func findsFansAndControl() {
        let fans = hardware(smc())
        #expect(fans.fanCount == 2)
        #expect(fans.supportsControl)
    }

    @Test func noFtstMeansNoControl() {
        let plain = smc()
        plain.values["Ftst"] = nil
        #expect(!hardware(plain).supportsControl)
    }

    @Test func readGivesGroupsAndIgnoresUnknownKeys() throws {
        let reading = try hardware(smc()).read()
        #expect(reading.cpuTemperature == 55)
        #expect(reading.hottestCPUTemperature == 60)
        #expect(reading.groupTemperatures == [.cpu: 60, .gpu: 55, .battery: 37, .airflow: 41.5])
        #expect(reading.fans.map(\.index) == [0, 1])
        #expect(reading.lidClosed == true)
    }

    @Test func aFanWithAMissingKeyIsLeftOutButKeepsItsIndex() throws {
        let partial = smc()
        partial.values["F0Ac"] = nil
        #expect(try hardware(partial).read().fans.map(\.index) == [1])
    }

    @Test func takingOverSetsTestFlagThenModeThenTarget() throws {
        let fake = smc()
        try hardware(fake).setTargets([2500, 3000])
        #expect(fake.writtenKeys == ["Ftst", "F0Md", "F0Tg", "Ftst", "F1Md", "F1Tg"])
        #expect(fake.writes[0].bytes == [1] && fake.writes[1].bytes == [1])
        #expect(fake.writes[2].bytes == target(2500) && fake.writes[5].bytes == target(3000))
    }

    @Test func heldFansOnlyGetTargets() throws {
        let fake = smc(fanModes: [1, 1])
        try hardware(fake).setTargets([2500, 3000])
        #expect(fake.writtenKeys == ["F0Tg", "F1Tg"])
    }

    @Test func wrongTargetCountTouchesNothing() {
        let fake = smc()
        #expect(throws: FanHardwareError.wrongFanCount(expected: 2, got: 1)) { try hardware(fake).setTargets([2500]) }
        #expect(fake.writes.isEmpty)
    }

    @Test func unsupportedMacTouchesNothing() {
        let fake = smc()
        fake.values["Ftst"] = nil
        #expect(throws: FanHardwareError.unsupported) { try hardware(fake).setTargets([2500, 3000]) }
        #expect(throws: FanHardwareError.unsupported) { try hardware(fake).setTargetsIfHeld([2500, 3000]) }
        #expect(fake.writes.isEmpty)
    }

    @Test func fanThatMacOSKeepsGetsNoTarget() {
        let fake = smc()
        fake.ignoredWrites = ["F0Md"]
        #expect(throws: FanHardwareError.notReleasedBySystem(fan: 0)) { try hardware(fake).setTargets([2500, 3000]) }
        #expect(!fake.writtenKeys.contains("F0Tg"))
    }

    @Test func ifHeldSkipsFansMacOSHas() throws {
        let fake = smc(fanModes: [0, 1])
        try hardware(fake).setTargetsIfHeld([2500, 3000])
        #expect(fake.writtenKeys == ["F1Tg"])
    }

    @Test func releaseHandsEveryFanBackThenClearsTheTestFlag() throws {
        let fake = smc(fanModes: [1, 1])
        try hardware(fake).releaseFans()
        #expect(fake.writtenKeys == ["F0Md", "F1Md", "Ftst"])
        #expect(fake.writes.allSatisfy { $0.bytes == [0] })
    }

    @Test func releaseGoesOnAfterAFailureAndReportsIt() {
        let fake = smc(fanModes: [1, 1])
        fake.failingWrites = ["F0Md"]
        #expect(throws: SMCError.self) { try hardware(fake).releaseFans() }
        #expect(fake.writtenKeys == ["F1Md", "Ftst"])
    }

    @Test func intelKeysAreTheFallback() throws {
        let intel = FakeSMC([("FNum", .byte(1)), ("F0Ac", .float(1800)), ("F0Mn", .float(1200)), ("F0Mx", .float(6000)),
                             ("TC0P", SMCValue(type: "sp78", bytes: [0x30, 0x00]))])
        let fans = hardware(intel)
        #expect(!fans.supportsControl)
        #expect(try fans.read().cpuTemperature == 48)
    }
}
