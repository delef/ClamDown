import Foundation

/// The type and raw bytes of the SMC keys ClamDown reads, taken from a real Mac. Tests replay a dump through a
/// stand-in SMC, so key discovery and decoding are checked against real data without the hardware.
public struct SMCKeyDump: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var key: String
        /// The four-letter type code, such as `flt ` or `sp78`.
        public var type: String
        /// The raw bytes as lowercase hex, two digits per byte.
        public var bytes: String

        public init(key: String, type: String, bytes: String) {
            self.key = key
            self.type = type
            self.bytes = bytes
        }

        var value: SMCValue? {
            let digits = Array(bytes.utf8)
            guard digits.count.isMultiple(of: 2) else { return nil }
            var raw: [UInt8] = []
            for index in stride(from: 0, to: digits.count, by: 2) {
                guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
                raw.append(byte)
            }
            return SMCValue(type: type, bytes: raw)
        }
    }

    /// Where the dump came from, such as "MacBook Pro M4 Pro, macOS 27.2". Free text.
    public var machine: String
    /// The SMC's own key order. Only the keys ClamDown may read are kept.
    public var entries: [Entry]

    public init(machine: String, entries: [Entry]) {
        self.machine = machine
        self.entries = entries
    }

    /// True for the keys ClamDown reads or writes: temperatures, fans, `FNum` and `Ftst`.
    static func isKept(_ key: String) -> Bool {
        key.hasPrefix("T") || key.hasPrefix("F")
    }

    /// Reads every kept key from this Mac's SMC. Read-only. Nil when the SMC cannot be opened.
    public static func capture(machine: String) -> SMCKeyDump? {
        guard let smc = SMC() else { return nil }
        let entries = (0..<smc.keyCount()).compactMap { index -> Entry? in
            guard let key = smc.key(at: index), isKept(key), let value = smc.read(key) else { return nil }
            return Entry(key: key, type: value.type, bytes: value.bytes.map { String(format: "%02x", $0) }.joined())
        }
        return SMCKeyDump(machine: machine, entries: entries)
    }
}
