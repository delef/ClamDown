import Foundation
import IOKit
import ClamDownShared

/// What the helper reads before it decides on fan speeds.
public struct HardwareReading: Equatable, Sendable {
    /// Average CPU temperature in °C. Nil when no CPU sensor could be read.
    public var cpuTemperature: Double?
    /// The hottest CPU core in °C. Nil when no CPU sensor could be read.
    public var hottestCPUTemperature: Double?
    public var fans: [FanReading]
    /// Nil when the lid state cannot be read.
    public var lidClosed: Bool?
    /// The hottest plausible value of each sensor group that could be read. Groups without one are absent.
    public var groupTemperatures: [SensorGroup: Double]
    /// The die-zone temperature the SMC steers each chip's fans by (`SensorKeys.zoneKeys`). Empty when this Mac
    /// has none or the check does not confirm them.
    public var zoneTemperatures: [SensorGroup: Double]

    public init(cpuTemperature: Double?, hottestCPUTemperature: Double? = nil, fans: [FanReading], lidClosed: Bool?,
                groupTemperatures: [SensorGroup: Double] = [:], zoneTemperatures: [SensorGroup: Double] = [:]) {
        self.cpuTemperature = cpuTemperature
        self.hottestCPUTemperature = hottestCPUTemperature
        self.fans = fans
        self.lidClosed = lidClosed
        self.groupTemperatures = groupTemperatures
        self.zoneTemperatures = zoneTemperatures
    }

    /// The hottest reading over all groups as read, in °C. The helper's curve follows the chips as their averaged
    /// zones instead (`FanDecision`). Nil when no group could be read.
    public var hottestTemperature: Double? { SensorGroup.hottest(in: groupTemperatures)?.celsius }
    /// The group of `hottestTemperature`.
    public var hottestGroup: SensorGroup? { SensorGroup.hottest(in: groupTemperatures)?.group }
}

public enum FanHardwareError: Error, Equatable, CustomStringConvertible {
    /// This Mac's SMC has no way to put the fans under manual control.
    case unsupported
    /// macOS did not hand the fan over within the wait.
    case notReleasedBySystem(fan: Int)
    /// A target list that does not cover every fan: taking the others would leave one with no target.
    case wrongFanCount(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .unsupported: "This Mac does not allow manual fan control."
        case .notReleasedBySystem(let fan): "macOS did not hand over fan \(fan + 1)."
        case .wrongFanCount(let expected, let got): "Expected targets for \(expected) fans, got \(got)."
        }
    }
}

/// Temperatures, fans and lid. Reading needs no privileges, so the app uses it too.
public protocol SensorReading: Sendable {
    func read() throws -> HardwareReading
}

/// The fans, temperature sensors and lid. Writing needs root, so only the helper drives the fans.
public protocol FanHardware: SensorReading {
    /// False when the fans can only be read, for example on an Intel Mac.
    var supportsControl: Bool { get }
    /// How many fans the hardware says it has (`FNum`). A reading can hold fewer when a fan's keys fail.
    var fanCount: Int { get }
    /// Takes the fans from macOS when needed and sets each fan's target speed in rpm, in fan order:
    /// `rpms[n]` goes to SMC fan n, whatever `read()` returned.
    func setTargets(_ rpms: [Double]) throws
    /// Sets the target of each fan that is still in manual mode, in fan order, and leaves a fan that macOS
    /// already has to macOS. Never takes a fan over, so it never waits for macOS.
    func setTargetsIfHeld(_ rpms: [Double]) throws
    /// Hands every fan back to macOS. Safe to call when ClamDown does not hold them.
    func releaseFans() throws
}

/// Fan control through the SMC, as on Apple Silicon: `Ftst` = 1 asks macOS to let go,
/// then `F<n>Md` = 1 puts fan n in manual mode and `F<n>Tg` sets its target speed.
public final class SMCFanHardware: FanHardware, @unchecked Sendable {
    private let lock = NSLock()
    private let smc: any SMCAccess
    /// The CPU keys, for the average and the hottest core.
    private let temperatureKeys: [String]
    /// Every key of every group this Mac has, in group order. CPU uses `temperatureKeys`.
    private let groupKeys: [(group: SensorGroup, keys: [String])]
    /// The zone keys, when this Mac has every one of them and the check key.
    private let zoneKeys: [(group: SensorGroup, key: String)]
    public let fanCount: Int
    public let supportsControl: Bool
    /// How long to wait for macOS to hand over a fan after `Ftst` = 1.
    private let takeoverTimeout: Duration
    /// Waits between take-over attempts.
    private let pause: @Sendable (Duration) -> Void
    private let lidReader: @Sendable () -> Bool?

    /// Nil when the SMC cannot be opened.
    public convenience init?(takeoverTimeout: Duration = .seconds(5)) {
        guard let smc = SMC() else { return nil }
        self.init(smc: smc, takeoverTimeout: takeoverTimeout)
    }

    init(smc: any SMCAccess, takeoverTimeout: Duration = .seconds(5),
         pause: @escaping @Sendable (Duration) -> Void = { Thread.sleep(forTimeInterval: Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) },
         lidClosed: @escaping @Sendable () -> Bool? = SMCFanHardware.lidClosed) {
        self.smc = smc
        self.takeoverTimeout = takeoverTimeout
        self.pause = pause
        lidReader = lidClosed
        fanCount = Int(smc.read("FNum")?.number ?? 0)
        let allKeys = (0..<smc.keyCount()).compactMap { smc.key(at: $0) }
        temperatureKeys = Self.findCPUTemperatureKeys(smc, allKeys: allKeys)
        groupKeys = Self.findGroupKeys(smc, allKeys: allKeys, cpu: temperatureKeys)
        let zoneKeysPresent = (SensorKeys.zoneKeys.map(\.key) + [SensorKeys.zoneCheckKey]).allSatisfy { smc.has($0) }
        zoneKeys = zoneKeysPresent ? SensorKeys.zoneKeys : []
        supportsControl = fanCount > 0 && smc.has("Ftst") && smc.read("F0Tg")?.type == "flt "
    }

    public func read() throws -> HardwareReading {
        lock.withLock {
            // A fan whose keys fail is left out, so each reading carries its SMC index: the helper must not
            // take the list as in fan order when one is missing, because `setTargets` writes by position.
            let fans = (0..<fanCount).compactMap { index -> FanReading? in
                guard let rpm = smc.read("F\(index)Ac")?.number,
                      let minimum = smc.read("F\(index)Mn")?.number,
                      let maximum = smc.read("F\(index)Mx")?.number else { return nil }
                return FanReading(rpm: rpm, minimum: minimum, maximum: maximum, index: index)
            }
            let cpuValues = temperatureKeys.compactMap { smc.read($0)?.number }
            let temperatures = CPUTemperatures.summary(cpuValues)
            var byGroup: [SensorGroup: [Double]] = [.cpu: cpuValues]
            for (group, keys) in groupKeys where group != .cpu {
                byGroup[group] = keys.compactMap { smc.read($0)?.number }
            }
            var zones: [SensorGroup: Double] = [:]
            for (group, key) in zoneKeys { zones[group] = smc.read(key)?.number }
            let check = zoneKeys.isEmpty ? nil : smc.read(SensorKeys.zoneCheckKey)?.number
            return HardwareReading(cpuTemperature: temperatures.average, hottestCPUTemperature: temperatures.hottest,
                                   fans: fans, lidClosed: lidReader(),
                                   groupTemperatures: SensorKeys.hottestByGroup(byGroup),
                                   zoneTemperatures: SensorKeys.confirmedZones(zones, check: check))
        }
    }

    /// Every temperature key this Mac has in the known groups, in group order. For device checks.
    public var sensorKeys: [(group: SensorGroup, keys: [String])] { groupKeys }

    /// The raw value of each key, unfiltered; nil where a key cannot be read. For device checks; changes nothing.
    public func readKeys(_ keys: [String]) -> [Double?] {
        lock.withLock { keys.map { smc.read($0)?.number } }
    }

    public func setTargets(_ rpms: [Double]) throws {
        guard supportsControl else { throw FanHardwareError.unsupported }
        // Every fan gets a target or none is touched: `Ftst` = 1 with a fan left out would leave that fan
        // with neither macOS nor ClamDown driving it.
        guard rpms.count == fanCount else { throw FanHardwareError.wrongFanCount(expected: fanCount, got: rpms.count) }
        try lock.withLock {
            for (index, rpm) in rpms.enumerated() {
                // macOS can take a fan back, for example after sleep, so check the mode every time.
                if smc.read("F\(index)Md")?.number != 1 { try takeOver(fan: index) }
                try smc.write("F\(index)Tg", bytes: Self.floatBytes(rpm))
            }
        }
    }

    public func setTargetsIfHeld(_ rpms: [Double]) throws {
        guard supportsControl else { throw FanHardwareError.unsupported }
        guard rpms.count == fanCount else { throw FanHardwareError.wrongFanCount(expected: fanCount, got: rpms.count) }
        try lock.withLock {
            var firstError: Error?
            for (index, rpm) in rpms.enumerated() where smc.read("F\(index)Md")?.number == 1 {
                do { try smc.write("F\(index)Tg", bytes: Self.floatBytes(rpm)) } catch { firstError = firstError ?? error }
            }
            if let firstError { throw firstError }
        }
    }

    /// What the SMC says about manual control: `Ftst` and each fan's `F<n>Md`, in fan order. Nil where a key cannot be read.
    /// For device checks; the helper does not use it.
    public func controlModes() -> (ftst: Double?, fanModes: [Double?]) {
        lock.withLock {
            (smc.read("Ftst")?.number, (0..<fanCount).map { smc.read("F\($0)Md")?.number })
        }
    }

    /// Writes `Ftst` = 1 and nothing else: no fan mode, no target. For device checks of what macOS does with a fan
    /// when only the test flag is set; the helper does not use it. `releaseFans()` undoes it.
    public func setTestFlagOnly() throws {
        guard supportsControl else { throw FanHardwareError.unsupported }
        try lock.withLock { try smc.write("Ftst", bytes: [1]) }
    }

    /// Tries even when control reads as unsupported: that reading can change between helper starts, and a take-over
    /// recorded by an earlier start must still be undone. A Mac without the keys has nothing to undo.
    public func releaseFans() throws {
        try lock.withLock {
            var firstError: Error?
            for index in 0..<fanCount where smc.has("F\(index)Md") {
                do { try smc.write("F\(index)Md", bytes: [0]) } catch { firstError = firstError ?? error }
            }
            if smc.has("Ftst") {
                do { try smc.write("Ftst", bytes: [0]) } catch { firstError = firstError ?? error }
            }
            if let firstError { throw firstError }
        }
    }

    private func takeOver(fan index: Int) throws {
        try smc.write("Ftst", bytes: [1])
        let deadline = ContinuousClock.now.advanced(by: takeoverTimeout)
        repeat {
            try? smc.write("F\(index)Md", bytes: [1])
            if smc.read("F\(index)Md")?.number == 1 { return }
            pause(.milliseconds(200))
        } while ContinuousClock.now < deadline
        throw FanHardwareError.notReleasedBySystem(fan: index)
    }

    /// Apple Silicon reports CPU core temperatures under `Tp*` (performance) and `Te*` (efficiency) as floats.
    /// Intel Macs use a few fixed `TC0*` keys instead.
    private static func findCPUTemperatureKeys(_ smc: any SMCAccess, allKeys: [String]) -> [String] {
        let appleSilicon = allKeys.filter { key in
            (key.hasPrefix("Tp") || key.hasPrefix("Te"))
                && smc.read(key).map { $0.type == "flt " && ($0.number.map(isPlausible) ?? false) } == true
        }
        if !appleSilicon.isEmpty { return appleSilicon }
        return ["TC0P", "TC0D", "TC0E", "TC0F"].filter { smc.read($0)?.number.map(isPlausible) == true }
    }

    /// CPU as found above; GPU is every `Tg*` key with a number (a value that is implausible now may be fine later,
    /// so plausibility is checked on each reading); the fixed keys where this Mac has them.
    private static func findGroupKeys(_ smc: any SMCAccess, allKeys: [String], cpu: [String]) -> [(group: SensorGroup, keys: [String])] {
        let gpu = allKeys.filter { SensorKeys.group(of: $0) == .gpu && smc.read($0)?.number != nil }
        let fixed = SensorKeys.fixed.map { group, keys in (group, keys.filter { smc.read($0)?.number != nil }) }
        return ([(SensorGroup.cpu, cpu), (.gpu, gpu)] + fixed).filter { !$0.1.isEmpty }
    }

    private static func isPlausible(_ celsius: Double) -> Bool { CPUTemperatures.isPlausible(celsius) }

    static func floatBytes(_ value: Double) -> [UInt8] {
        withUnsafeBytes(of: Float(value)) { Array($0) }
    }

    static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }
}
