import Foundation
import IOKit

public enum SMCError: Error, Equatable, CustomStringConvertible {
    case keyMissing(String)
    case callFailed(key: String, kernReturn: Int32, result: UInt8)

    public var description: String {
        switch self {
        case .keyMissing(let key): "SMC key \(key) does not exist"
        case .callFailed(let key, let kr, let result): "SMC call for \(key) failed (kern \(kr), result \(result))"
        }
    }
}

/// A typed value read from the SMC: the four-letter type code and the raw bytes.
struct SMCValue: Equatable {
    let type: String
    let bytes: [UInt8]

    /// Decodes the numeric types ClamDown uses. Nil for any other type.
    var number: Double? {
        switch type {
        case "flt " where bytes.count == 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 " where bytes.count >= 1:
            return Double(bytes[0])
        case "ui16" where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count >= 4:
            return Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "sp78" where bytes.count >= 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2" where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default:
            return nil
        }
    }
}

// The layout of the kernel's SMCParamStruct (80 bytes). The explicit padding keeps
// Swift's layout identical to the C one; `IOKitSMCDriver.init` checks the size before any call.
struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPowerLimit {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0
}

struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var attributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCParam {
    var key: UInt32 = 0
    var version = SMCVersion()
    var powerLimit = SMCPowerLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var index: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// The SMC calls ClamDown makes. `SMC` talks to the hardware; tests use a stand-in that records every write.
/// Not thread-safe: the owner serialises access.
protocol SMCAccess: AnyObject {
    func keyCount() -> Int
    /// The name of the key at `index` in the SMC's key list.
    func key(at index: Int) -> String?
    func read(_ key: String) -> SMCValue?
    func write(_ key: String, bytes: [UInt8]) throws
    func has(_ key: String) -> Bool
}

/// One call into the SMC driver: the input structure in, the kernel's return code and the output structure out.
/// `IOKitSMCDriver` talks to the hardware; tests answer the calls from a key dump.
protocol SMCDriver: AnyObject {
    func call(_ input: SMCParam) -> (kern_return_t, SMCParam)
}

/// The open connection to the AppleSMC driver.
final class IOKitSMCDriver: SMCDriver {
    private static let handleEvent: UInt32 = 2

    private let connection: io_connect_t

    /// Nil when the SMC cannot be opened, as on a virtual Mac, or when `SMCParam` lost the kernel's layout.
    init?() {
        guard MemoryLayout<SMCParam>.stride == 80, MemoryLayout<SMCParam>.offset(of: \SMCParam.bytes) == 48 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        self.connection = connection
    }

    deinit { IOServiceClose(connection) }

    func call(_ input: SMCParam) -> (kern_return_t, SMCParam) {
        var input = input
        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(connection, Self.handleEvent, &input, MemoryLayout<SMCParam>.stride, &output, &outputSize)
        return (kr, output)
    }
}

/// A minimal client for the System Management Controller. Reading works for any user; writing needs root.
/// Not thread-safe: the owner serialises access.
final class SMC: SMCAccess {
    enum Command: UInt8 {
        case readKey = 5
        case writeKey = 6
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private let driver: any SMCDriver
    private var infoCache: [UInt32: SMCKeyInfo] = [:]

    /// Nil when the SMC cannot be opened.
    convenience init?() {
        guard let driver = IOKitSMCDriver() else { return nil }
        self.init(driver: driver)
    }

    init(driver: any SMCDriver) {
        self.driver = driver
    }

    func keyCount() -> Int {
        read("#KEY")?.number.map { Int($0) } ?? 0
    }

    /// The name of the key at `index` in the SMC's key list.
    func key(at index: Int) -> String? {
        var input = SMCParam()
        input.command = Command.keyAtIndex.rawValue
        input.index = UInt32(index)
        guard let output = try? call(input, key: "#\(index)") else { return nil }
        return Self.name(output.key)
    }

    func read(_ key: String) -> SMCValue? {
        let code = Self.code(key)
        guard let info = keyInfo(code) else { return nil }
        var input = SMCParam()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.command = Command.readKey.rawValue
        guard let output = try? call(input, key: key) else { return nil }
        let size = min(Int(info.dataSize), 32)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return SMCValue(type: Self.name(info.dataType), bytes: bytes)
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        let code = Self.code(key)
        guard let info = keyInfo(code) else { throw SMCError.keyMissing(key) }
        var input = SMCParam()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.command = Command.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (offset, byte) in bytes.prefix(min(Int(info.dataSize), 32)).enumerated() { buffer[offset] = byte }
        }
        _ = try call(input, key: key)
    }

    func has(_ key: String) -> Bool { keyInfo(Self.code(key)) != nil }

    private func keyInfo(_ code: UInt32) -> SMCKeyInfo? {
        if let cached = infoCache[code] { return cached }
        var input = SMCParam()
        input.key = code
        input.command = Command.keyInfo.rawValue
        guard let output = try? call(input, key: Self.name(code)) else { return nil }
        infoCache[code] = output.keyInfo
        return output.keyInfo
    }

    private func call(_ input: SMCParam, key: String) throws -> SMCParam {
        let (kr, output) = driver.call(input)
        guard kr == KERN_SUCCESS, output.result == 0 else {
            throw SMCError.callFailed(key: key, kernReturn: kr, result: output.result)
        }
        return output
    }

    static func code(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func name(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }, as: UTF8.self)
    }
}
