import Foundation

/// One point of a fan curve: at this CPU temperature (whole °C) the fans run at this speed
/// (whole percent of each fan's range: 0 is the fan's minimum rpm, 100 its maximum).
public struct FanPoint: Codable, Equatable, Sendable {
    public var temperature: Int
    public var speed: Int

    public init(temperature: Int, speed: Int) {
        self.temperature = temperature
        self.speed = speed
    }
}

/// The least the fans run at, whatever the curve says: 0 % up to 70 °C, a straight line to 100 % at 95 °C,
/// and 100 % above. It keeps a hot Mac from running with slow fans.
public enum SafetyFloor {
    public static let rampStart = 70
    public static let rampEnd = 95

    /// The floor's speed in percent at this CPU temperature.
    public static func speed(at temperature: Double) -> Double {
        let start = Double(rampStart), end = Double(rampEnd)
        if temperature <= start { return 0 }
        if temperature >= end { return 100 }
        return (temperature - start) * 100 / (end - start)
    }
}

/// What the app asks the helper to do with the fans: a curve of points over the CPU temperature.
/// No points means fan control is switched off. The helper repairs the policy again before use.
public struct FanPolicy: Codable, Equatable, Sendable {
    public static let temperatureRange = 40...100
    public static let speedRange = 0...100

    public var points: [FanPoint]
    /// Leaves the fans to macOS while the lid is open.
    public var onlyWhenLidClosed: Bool

    public init(points: [FanPoint], onlyWhenLidClosed: Bool = true) {
        self.points = points
        self.onlyWhenLidClosed = onlyWhenLidClosed
    }

    /// True when ClamDown leaves the fans to macOS.
    public var isOff: Bool { points.isEmpty }

    /// Brings every point into range, then raises each point to at least the temperature and the speed
    /// of the one before it, so the curve never runs backwards.
    public func repaired() -> FanPolicy {
        var copy = self
        var previous: FanPoint?
        copy.points = points.map { point in
            var fixed = FanPoint(temperature: Self.clamp(point.temperature, to: Self.temperatureRange),
                                 speed: Self.clamp(point.speed, to: Self.speedRange))
            if let previous {
                fixed.temperature = max(fixed.temperature, previous.temperature)
                fixed.speed = max(fixed.speed, previous.speed)
            }
            previous = fixed
            return fixed
        }
        return copy
    }

    /// The curve's own speed in percent, without the safety floor. Flat before the first point and after
    /// the last, straight lines in between; where two points share a temperature, the higher speed applies.
    /// Expects a repaired policy.
    public func curveSpeed(at temperature: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if temperature < Double(first.temperature) { return Double(first.speed) }
        if temperature > Double(last.temperature) { return Double(last.speed) }
        let matching = points.filter { Double($0.temperature) == temperature }
        if let highest = matching.map(\.speed).max() { return Double(highest) }
        for (from, to) in zip(points, points.dropFirst())
        where Double(from.temperature) < temperature && temperature < Double(to.temperature) {
            let t0 = Double(from.temperature), t1 = Double(to.temperature)
            return Double(from.speed) + Double(to.speed - from.speed) * (temperature - t0) / (t1 - t0)
        }
        return Double(last.speed)
    }

    /// The speed in percent the fans run at: the higher of the curve and the safety floor; 0 when off.
    public func speed(at temperature: Double) -> Double {
        guard !isOff else { return 0 }
        let wanted = max(curveSpeed(at: temperature), SafetyFloor.speed(at: temperature))
        return min(max(wanted, Double(Self.speedRange.lowerBound)), Double(Self.speedRange.upperBound))
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The simple curve: "speeds up from" a temperature at 0 %, "full speed at" a higher one at 100 %.
/// Its ranges keep the line out of the safety floor.
public enum StandardCurve {
    public static let startRange = 40...70
    public static let fullSpeedMaximum = 95
    /// The full-speed point stays at least this many degrees above the start point.
    public static let minimumSpan = 5
    // The curve starts early on purpose: a closed Mac in a bag has little airflow, and running long matters more than quiet.
    public static let defaultStart = 50
    public static let defaultFull = 75

    public static func points(start: Int, full: Int) -> [FanPoint] {
        [FanPoint(temperature: start, speed: 0), FanPoint(temperature: full, speed: 100)]
    }

    /// Moves both temperatures to the nearest allowed values.
    public static func clamped(start: Int, full: Int) -> (start: Int, full: Int) {
        let start = FanPolicy.clamp(start, to: startRange)
        let full = FanPolicy.clamp(full, to: (start + minimumSpan)...fullSpeedMaximum)
        return (start, full)
    }
}

/// One fan as the SMC reports it. Speeds are in rpm.
public struct FanReading: Codable, Equatable, Sendable {
    public var rpm: Double
    public var minimum: Double
    public var maximum: Double

    public init(rpm: Double, minimum: Double, maximum: Double) {
        self.rpm = rpm
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// Why the fans run at full speed whatever the curve says.
public enum FanOverride: String, Codable, Sendable {
    /// The hottest CPU core has been at its limit for a while.
    case hotCore
    /// macOS reports the Mac's thermal level as serious or critical.
    case system
}

/// What the helper is doing with the fans.
public enum FanControlState: String, Codable, Sendable {
    /// Not asked to control them, or the lid is open with Only With Lid Closed: macOS has the fans.
    case idle
    /// ClamDown sets the fan speeds.
    case controlling
    /// A fault handed the fans back to macOS; the helper takes them again by itself soon.
    case retrying
    /// Several faults in a row: macOS has the fans and the helper only tries again now and then.
    case stopped
}

/// Temperatures and fans as the helper sees them right now.
public struct CoolingStatus: Codable, Equatable, Sendable {
    /// Average CPU temperature in °C. Nil when it cannot be read.
    public var cpuTemperature: Double?
    /// The hottest CPU core in °C. Nil when it cannot be read.
    public var hottestCPUTemperature: Double?
    public var fans: [FanReading]
    /// True while ClamDown, not macOS, sets the fan speed.
    public var isControlling: Bool
    /// Why fan control does not work, when it does not.
    public var problem: String?
    /// Why the fans run at full speed, when they do whatever the curve says.
    public var override: FanOverride?
    public var control: FanControlState
    /// The thermal level macOS reports to the helper itself. Nil when the helper does not read it.
    public var systemThermalLevel: ThermalLevel?

    public init(cpuTemperature: Double?, hottestCPUTemperature: Double? = nil, fans: [FanReading], isControlling: Bool,
                problem: String?, override: FanOverride? = nil, control: FanControlState = .idle,
                systemThermalLevel: ThermalLevel? = nil) {
        self.cpuTemperature = cpuTemperature
        self.hottestCPUTemperature = hottestCPUTemperature
        self.fans = fans
        self.isControlling = isControlling
        self.problem = problem
        self.override = override
        self.control = control
        self.systemThermalLevel = systemThermalLevel
    }

    /// An older helper sends none of the newer fields, and a later one may send values this build does not know:
    /// those read as unknown instead of failing the whole status.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuTemperature = try container.decodeIfPresent(Double.self, forKey: .cpuTemperature)
        hottestCPUTemperature = try container.decodeIfPresent(Double.self, forKey: .hottestCPUTemperature)
        fans = try container.decode([FanReading].self, forKey: .fans)
        isControlling = try container.decode(Bool.self, forKey: .isControlling)
        problem = try container.decodeIfPresent(String.self, forKey: .problem)
        override = (try? container.decodeIfPresent(FanOverride.self, forKey: .override)) ?? nil
        control = (try? container.decodeIfPresent(FanControlState.self, forKey: .control)) ?? .idle
        systemThermalLevel = (try? container.decodeIfPresent(ThermalLevel.self, forKey: .systemThermalLevel)) ?? nil
    }
}
