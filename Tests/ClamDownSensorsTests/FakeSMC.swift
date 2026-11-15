import Foundation
import Testing
@testable import ClamDownSensors

/// A stand-in SMC: keys with types and bytes, every write recorded in order.
final class FakeSMC: SMCAccess, @unchecked Sendable {
    struct Write: Equatable {
        var key: String
        var bytes: [UInt8]
    }

    private(set) var keys: [String]
    var values: [String: SMCValue]
    private(set) var writes: [Write] = []
    /// Writes to these keys throw, as when the helper lacks root or the SMC refuses.
    var failingWrites: Set<String> = []
    /// Writes to these keys are accepted but change nothing, as when macOS keeps a fan.
    var ignoredWrites: Set<String> = []

    init(_ values: [(String, SMCValue)]) {
        keys = values.map(\.0)
        self.values = Dictionary(values, uniquingKeysWith: { _, last in last })
    }

    /// The keys of a dump taken from a real Mac.
    convenience init(dump: SMCKeyDump) {
        self.init(dump.entries.compactMap { entry in entry.value.map { (entry.key, $0) } })
    }

    static func fixture(_ name: String) throws -> SMCKeyDump {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(SMCKeyDump.self, from: Data(contentsOf: url))
    }

    func keyCount() -> Int { keys.count }
    func key(at index: Int) -> String? { keys.indices.contains(index) ? keys[index] : nil }
    func read(_ key: String) -> SMCValue? { values[key] }
    func has(_ key: String) -> Bool { values[key] != nil }

    func write(_ key: String, bytes: [UInt8]) throws {
        guard let current = values[key] else { throw SMCError.keyMissing(key) }
        if failingWrites.contains(key) { throw SMCError.callFailed(key: key, kernReturn: -1, result: 0x84) }
        writes.append(Write(key: key, bytes: bytes))
        if !ignoredWrites.contains(key) { values[key] = SMCValue(type: current.type, bytes: bytes) }
    }

    /// The written keys, in order.
    var writtenKeys: [String] { writes.map(\.key) }
}

extension SMCValue {
    static func float(_ value: Float) -> SMCValue { SMCValue(type: "flt ", bytes: withUnsafeBytes(of: value) { Array($0) }) }
    static func byte(_ value: UInt8) -> SMCValue { SMCValue(type: "ui8 ", bytes: [value]) }
}
