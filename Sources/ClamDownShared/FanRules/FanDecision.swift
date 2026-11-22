import Foundation

/// How ClamDown decides how fast the fans run. Every rule and number behind that decision lives in this folder
/// (`FanRules`); the helper only reads the sensors, hands the result to the SMC and handles faults. Which SMC keys
/// make up each sensor group and each chip's die zone is the sensor adapter's table, `SensorKeys`.
///
/// Each reading goes through these steps, in this order:
/// 1. **What the curve follows** (`observe`): the hottest of the sensor groups, each chip (CPU, GPU) as the die zone
///    macOS steers by, averaged over time (`SustainedTemperatures`); the other groups as read.
/// 2. **The speed the rules ask for** (`FanPolicy.speed`): the highest of the user's curve, the safety floor
///    (`SafetyFloor`) on that temperature, and the case rule (`CaseRamp`) on the airflow sensors.
/// 3. **Full speed instead** (`override`): a CPU core at its limit, then a hot battery (`OverheatWatch`), then macOS
///    reporting the Mac as hot (`systemLevelForFullSpeed`), in that order.
/// 4. **Revolutions per minute** (`targets`): the percent of each fan's own range, rising at once and falling by at
///    most `fallStep` per `fallInterval`, inside the fan's minimum and maximum.
public struct FanDecision: Sendable {
    /// From this level of macOS's own thermal state the fans run at full speed.
    public static let systemLevelForFullSpeed = ThermalLevel.serious
    /// How far a fan's target may fall per `fallInterval`, in rpm, so a short dip in load does not make the fans hunt.
    /// The fall is limited by time, not by reading: a burst of readings must not drop the fans faster.
    public static let fallStep = 150.0
    public static let fallInterval: Duration = .seconds(3)

    /// The sensor values one decision needs, as the sensor adapter reads them.
    public struct Sensors: Sendable {
        /// The hottest plausible value of each group that could be read.
        public var groups: [SensorGroup: Double]
        /// Each chip's confirmed die zone; empty when the Mac has none.
        public var zones: [SensorGroup: Double]
        /// The hottest CPU core, for the hot-core watch.
        public var hottestCore: Double?
        /// The average CPU temperature: what the curve follows when no group can be read.
        public var cpuAverage: Double?

        public init(groups: [SensorGroup: Double], zones: [SensorGroup: Double] = [:], hottestCore: Double? = nil,
                    cpuAverage: Double? = nil) {
            self.groups = groups
            self.zones = zones
            self.hottestCore = hottestCore
            self.cpuAverage = cpuAverage
        }
    }

    /// The outcome of step 1, with the watches of step 3.
    public struct Observation: Sendable, Equatable {
        /// Each group as the curve follows it.
        public var followed: [SensorGroup: Double]
        /// The temperature the curve and the floor follow. Nil when nothing can be read.
        public var temperature: Double?
        public var hotCore: Bool
        public var hotBattery: Bool
    }

    private var chips = SustainedTemperatures()
    private var hotCore = OverheatWatch.hotCore()
    private var hotBattery = OverheatWatch.hotBattery()

    public init() {}

    /// Step 1, and the watches of step 3. Call it with every reading, also while the fans are left to macOS (with
    /// the lid open, say), so the averages and the watches are already right when ClamDown takes the fans.
    public mutating func observe(_ sensors: Sensors, now: SuspendingClock.Instant) -> Observation {
        let core = hotCore.update(hottest: sensors.hottestCore, now: now)
        let battery = hotBattery.update(hottest: sensors.groups[.battery], now: now)
        let followed = chips.update(groups: sensors.groups, zones: sensors.zones, now: now)
        return Observation(followed: followed, temperature: Self.temperature(followed, cpuAverage: sensors.cpuAverage),
                           hotCore: core, hotBattery: battery)
    }

    /// The groups as the curve follows them now, without taking a reading; for the status.
    public func followed(_ sensors: Sensors) -> [SensorGroup: Double] {
        chips.applied(groups: sensors.groups, zones: sensors.zones)
    }

    /// Step 3: why the fans run at full speed, if they do. `systemLevel` is read only when it decides.
    public static func override(_ observation: Observation, systemLevel: @autoclosure () -> ThermalLevel?) -> FanOverride? {
        if observation.hotCore { return .hotCore }
        if observation.hotBattery { return .hotBattery }
        if let level = systemLevel(), level >= systemLevelForFullSpeed { return .system }
        return nil
    }

    /// Steps 2 and 3: the speed in percent of each fan's range. Expects a repaired policy and a temperature.
    public static func percent(policy: FanPolicy, temperature: Double, airflow: Double?, override: FanOverride?) -> Double {
        override == nil ? policy.speed(at: temperature, caseTemperature: airflow) : 100
    }

    /// Step 4: each fan's target in rpm, in the order of `fans`. `previous` are the targets last set, in the same
    /// order; `maxDrop` is how far they may fall now (`allowedDrop`).
    public static func targets(percent: Double, fans: [FanReading], previous: [Double]?, maxDrop: Double) -> [Double] {
        fans.enumerated().map { index, fan in
            let wanted = speed(percent: percent, fan: fan)
            let before = previous.flatMap { index < $0.count ? $0[index] : nil }
            return min(max(smoothed(previous: before, wanted: wanted, maxDrop: maxDrop), fan.minimum), fan.maximum)
        }
    }

    /// How far the targets may fall `elapsed` after they were last set: `step` for each `interval`, never more than
    /// one step. Nil `elapsed` (nothing set yet) allows a whole step; calls close together share the step.
    public static func allowedDrop(after elapsed: Duration?, step: Double = fallStep,
                                   interval: Duration = fallInterval) -> Double {
        guard let elapsed else { return step }
        guard elapsed > .zero else { return 0 }
        return step * min(elapsed / interval, 1)
    }

    /// A speed in percent of the fan's range (0 is its minimum, 100 its maximum) in rpm.
    public static func speed(percent: Double, fan: FanReading) -> Double {
        fan.minimum + (fan.maximum - fan.minimum) * percent / 100
    }

    /// Speeds rise at once but fall by at most `maxDrop` rpm per step.
    public static func smoothed(previous: Double?, wanted: Double, maxDrop: Double) -> Double {
        guard let previous, wanted < previous else { return wanted }
        return max(wanted, previous - maxDrop)
    }

    /// The hottest followed group, or the average CPU temperature when no group can be read.
    private static func temperature(_ followed: [SensorGroup: Double], cpuAverage: Double?) -> Double? {
        SensorGroup.hottest(in: followed)?.celsius ?? cpuAverage
    }
}
