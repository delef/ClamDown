import Foundation
import IOKit
import Testing
@testable import ClamDownSensors

/// The SMC client against a stand-in driver that answers the kernel's SMCParamStruct calls the way the SMC does,
/// so the key list, reads and writes are checked without the hardware.
@Suite struct SMCTests {
    @Test func theStructurePassedToTheKernelHasTheKernelsLayout() {
        #expect(MemoryLayout<SMCParam>.stride == 80)
        #expect(MemoryLayout<SMCParam>.offset(of: \SMCParam.bytes) == 48)
    }

    @Test(arguments: KeyDumpTests.dumps) func aCaptureThroughTheDriverGivesBackTheDump(name: String) throws {
        let dump = try FakeSMC.fixture(name)
        // The SMC also lists keys ClamDown never reads; the capture leaves them out.
        var entries = dump.entries
        entries.insert(SMCKeyDump.Entry(key: "BNum", type: "ui8 ", bytes: "01"), at: 1)
        let driver = FakeSMCDriver(SMCKeyDump(machine: dump.machine, entries: entries))
        #expect(SMCKeyDump.capture(machine: dump.machine, smc: SMC(driver: driver)) == dump)
    }

    @Test func aWriteSendsTheKeysOwnSizeOfBytes() throws {
        let driver = FakeSMCDriver(SMCKeyDump(machine: "", entries: [.init(key: "F0Md", type: "ui8 ", bytes: "00")]))
        let smc = SMC(driver: driver)
        try smc.write("F0Md", bytes: [1, 9, 9])
        #expect(driver.writes == [FakeSMCDriver.Write(key: "F0Md", bytes: [1])])
        #expect(smc.read("F0Md") == SMCValue(type: "ui8 ", bytes: [1]))
    }

    @Test func aMissingKeyReadsAsNothingAndCannotBeWritten() {
        let smc = SMC(driver: FakeSMCDriver(SMCKeyDump(machine: "", entries: [])))
        #expect(smc.read("TC0P") == nil)
        #expect(!smc.has("TC0P"))
        #expect(smc.key(at: 1) == nil, "past the end of the key list, which holds only #KEY")
        #expect(throws: SMCError.keyMissing("TC0P")) { try smc.write("TC0P", bytes: [0]) }
    }

    @Test func aWriteTheSMCRefusesIsAnError() {
        let driver = FakeSMCDriver(SMCKeyDump(machine: "", entries: [.init(key: "F0Md", type: "ui8 ", bytes: "00")]))
        driver.refusedWrites = ["F0Md"]
        #expect(throws: SMCError.callFailed(key: "F0Md", kernReturn: KERN_SUCCESS, result: FakeSMCDriver.notWritable)) {
            try SMC(driver: driver).write("F0Md", bytes: [1])
        }
    }
}

/// Answers SMCParamStruct calls from a key dump, as the SMC driver does: key info, read, write and key by index.
final class FakeSMCDriver: SMCDriver, @unchecked Sendable {
    struct Write: Equatable {
        var key: String
        var bytes: [UInt8]
    }

    /// The SMC's result codes for a missing key and a refused write.
    static let keyNotFound: UInt8 = 0x84
    static let notWritable: UInt8 = 0x87

    private var keys: [String]
    private var values: [String: SMCValue]
    private(set) var writes: [Write] = []
    var refusedWrites: Set<String> = []

    init(_ dump: SMCKeyDump) {
        let entries = dump.entries.compactMap { entry in entry.value.map { (entry.key, $0) } }
        // The SMC answers "#KEY" with the number of keys it lists, as a big-endian ui32.
        let count = UInt32(entries.count + 1)
        let countBytes = [24, 16, 8, 0].map { UInt8((count >> UInt32($0)) & 0xff) }
        keys = ["#KEY"] + entries.map(\.0)
        values = Dictionary(entries, uniquingKeysWith: { _, last in last })
        values["#KEY"] = SMCValue(type: "ui32", bytes: countBytes)
    }

    func call(_ input: SMCParam) -> (kern_return_t, SMCParam) {
        var output = SMCParam()
        let key = SMC.name(input.key)
        switch input.command {
        case SMC.Command.keyInfo.rawValue:
            guard let value = values[key] else { return (KERN_SUCCESS, notFound()) }
            output.keyInfo.dataSize = UInt32(value.bytes.count)
            output.keyInfo.dataType = SMC.code(value.type)
        case SMC.Command.readKey.rawValue:
            guard let value = values[key] else { return (KERN_SUCCESS, notFound()) }
            withUnsafeMutableBytes(of: &output.bytes) { buffer in
                for (offset, byte) in value.bytes.prefix(Int(input.keyInfo.dataSize)).enumerated() { buffer[offset] = byte }
            }
        case SMC.Command.writeKey.rawValue:
            guard let value = values[key] else { return (KERN_SUCCESS, notFound()) }
            if refusedWrites.contains(key) {
                output.result = Self.notWritable
                return (KERN_SUCCESS, output)
            }
            let bytes = withUnsafeBytes(of: input.bytes) { Array($0.prefix(Int(input.keyInfo.dataSize))) }
            writes.append(Write(key: key, bytes: bytes))
            values[key] = SMCValue(type: value.type, bytes: bytes)
        case SMC.Command.keyAtIndex.rawValue:
            guard keys.indices.contains(Int(input.index)) else { return (KERN_SUCCESS, notFound()) }
            output.key = SMC.code(keys[Int(input.index)])
        default:
            return (kIOReturnUnsupported, output)
        }
        return (KERN_SUCCESS, output)
    }

    private func notFound() -> SMCParam {
        var output = SMCParam()
        output.result = Self.keyNotFound
        return output
    }
}
