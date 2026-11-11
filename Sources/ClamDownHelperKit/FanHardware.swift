import Foundation
import IOKit
import ClamDownShared

/// What the helper reads before it decides on fan speeds.
public struct HardwareReading: Equatable, Sendable {
    /// Average CPU temperature in °C. Nil when no CPU sensor could be read.
    public var cpuTemperature: Double?
    public var fans: [FanReading]
    /// Nil when the lid state cannot be read.
    public var lidClosed: Bool?

    public init(cpuTemperature: Double?, fans: [FanReading], lidClosed: Bool?) {
        self.cpuTemperature = cpuTemperature
        self.fans = fans
        self.lidClosed = lidClosed
    }
}

public enum FanHardwareError: Error, Equatable, CustomStringConvertible {
    /// This Mac's SMC has no way to put the fans under manual control.
    case unsupported
    /// macOS did not hand the fan over within the wait.
    case notReleasedBySystem(fan: Int)

    public var description: String {
        switch self {
        case .unsupported: "This Mac does not allow manual fan control."
        case .notReleasedBySystem(let fan): "macOS did not hand over fan \(fan + 1)."
        }
    }
}

/// The fans, temperature sensors and lid. Everything here needs root to write.
public protocol FanHardware: Sendable {
    /// False when the fans can only be read, for example on an Intel Mac.
    var supportsControl: Bool { get }
    func read() throws -> HardwareReading
    /// Takes the fans from macOS when needed and sets each fan's target speed in rpm, in fan order.
    func setTargets(_ rpms: [Double]) throws
    /// Hands every fan back to macOS. Safe to call when ClamDown does not hold them.
    func releaseFans() throws
}

/// Fan control through the SMC, as on Apple Silicon: `Ftst` = 1 asks macOS to let go,
/// then `F<n>Md` = 1 puts fan n in manual mode and `F<n>Tg` sets its target speed.
public final class SMCFanHardware: FanHardware, @unchecked Sendable {
    private let lock = NSLock()
    private let smc: SMC
    private let temperatureKeys: [String]
    private let fanCount: Int
    public let supportsControl: Bool
    /// How long to wait for macOS to hand over a fan after `Ftst` = 1.
    private let takeoverTimeout: Duration

    /// Nil when the SMC cannot be opened.
    public init?(takeoverTimeout: Duration = .seconds(5)) {
        guard let smc = SMC() else { return nil }
        self.smc = smc
        self.takeoverTimeout = takeoverTimeout
        fanCount = Int(smc.read("FNum")?.number ?? 0)
        temperatureKeys = Self.findCPUTemperatureKeys(smc)
        supportsControl = fanCount > 0 && smc.has("Ftst") && smc.read("F0Tg")?.type == "flt "
    }

    public func read() throws -> HardwareReading {
        lock.withLock {
            let fans = (0..<fanCount).compactMap { index -> FanReading? in
                guard let rpm = smc.read("F\(index)Ac")?.number,
                      let minimum = smc.read("F\(index)Mn")?.number,
                      let maximum = smc.read("F\(index)Mx")?.number else { return nil }
                return FanReading(rpm: rpm, minimum: minimum, maximum: maximum)
            }
            let temperatures = temperatureKeys.compactMap { smc.read($0)?.number }.filter(Self.isPlausible)
            let average = temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count)
            return HardwareReading(cpuTemperature: average, fans: fans, lidClosed: Self.lidClosed())
        }
    }

    public func setTargets(_ rpms: [Double]) throws {
        guard supportsControl else { throw FanHardwareError.unsupported }
        try lock.withLock {
            for (index, rpm) in rpms.prefix(fanCount).enumerated() {
                // macOS can take a fan back, for example after sleep, so check the mode every time.
                if smc.read("F\(index)Md")?.number != 1 { try takeOver(fan: index) }
                try smc.write("F\(index)Tg", bytes: Self.floatBytes(rpm))
            }
        }
    }

    public func releaseFans() throws {
        guard supportsControl else { return }
        try lock.withLock {
            var firstError: Error?
            for index in 0..<fanCount {
                do { try smc.write("F\(index)Md", bytes: [0]) } catch { firstError = firstError ?? error }
            }
            do { try smc.write("Ftst", bytes: [0]) } catch { firstError = firstError ?? error }
            if let firstError { throw firstError }
        }
    }

    private func takeOver(fan index: Int) throws {
        try smc.write("Ftst", bytes: [1])
        let deadline = ContinuousClock.now.advanced(by: takeoverTimeout)
        repeat {
            try? smc.write("F\(index)Md", bytes: [1])
            if smc.read("F\(index)Md")?.number == 1 { return }
            Thread.sleep(forTimeInterval: 0.2)
        } while ContinuousClock.now < deadline
        throw FanHardwareError.notReleasedBySystem(fan: index)
    }

    /// Apple Silicon reports CPU core temperatures under `Tp*` (performance) and `Te*` (efficiency) as floats.
    /// Intel Macs use a few fixed `TC0*` keys instead.
    private static func findCPUTemperatureKeys(_ smc: SMC) -> [String] {
        let appleSilicon = (0..<smc.keyCount()).compactMap { smc.key(at: $0) }.filter { key in
            (key.hasPrefix("Tp") || key.hasPrefix("Te"))
                && smc.read(key).map { $0.type == "flt " && ($0.number.map(isPlausible) ?? false) } == true
        }
        if !appleSilicon.isEmpty { return appleSilicon }
        return ["TC0P", "TC0D", "TC0E", "TC0F"].filter { smc.read($0)?.number.map(isPlausible) == true }
    }

    /// Unused sensors read 0 or nonsense; real CPU temperatures fall in this range.
    private static func isPlausible(_ celsius: Double) -> Bool { celsius > 10 && celsius < 130 }

    private static func floatBytes(_ value: Double) -> [UInt8] {
        withUnsafeBytes(of: Float(value)) { Array($0) }
    }

    private static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }
}
