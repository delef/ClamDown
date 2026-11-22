import Foundation

/// One point of a fan curve: at this temperature (whole °C, of the hottest sensor group as the helper follows it, each
/// chip as the die zone macOS steers by, averaged over half a minute) the fans run at this speed
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

    /// The floor's speed in percent at this temperature.
    public static func speed(at temperature: Double) -> Double {
        let start = Double(rampStart), end = Double(rampEnd)
        if temperature <= start { return 0 }
        if temperature >= end { return 100 }
        return (temperature - start) * 100 / (end - start)
    }
}

/// The case rule: the fans speed up with the airflow sensors, which follow the Mac's case, apart from the curve.
/// A case can feel hot while the chips are only warm, so it gets its own, lower temperatures:
/// 0 % at `start`, 100 % at `full`, a straight line in between.
public struct CaseRamp: Codable, Equatable, Sendable {
    public static let startRange = 30...50
    public static let fullSpeedMaximum = 60
    /// The full-speed point stays at least this many degrees above the start point.
    public static let minimumSpan = 2
    public static let defaultStart = 38
    public static let defaultFull = 44
    public static let standard = CaseRamp(start: defaultStart, full: defaultFull)

    public var start: Int
    public var full: Int

    public init(start: Int, full: Int) {
        self.start = start
        self.full = full
    }

    /// Moves both temperatures to the nearest allowed values.
    public func clamped() -> CaseRamp {
        let start = FanPolicy.clamp(start, to: Self.startRange)
        return CaseRamp(start: start, full: FanPolicy.clamp(full, to: (start + Self.minimumSpan)...Self.fullSpeedMaximum))
    }

    /// The speed in percent for this case temperature. Expects a clamped ramp.
    public func speed(at temperature: Double) -> Double {
        let start = Double(start), full = Double(full)
        if temperature <= start { return 0 }
        if temperature >= full { return 100 }
        return (temperature - start) * 100 / (full - start)
    }
}

/// What the app asks the helper to do with the fans: a curve of points over the hottest temperature.
/// No points means fan control is switched off. The helper repairs the policy again before use.
public struct FanPolicy: Codable, Equatable, Sendable {
    public static let temperatureRange = 40...100
    public static let speedRange = 0...100

    public var points: [FanPoint]
    /// Leaves the fans to macOS while the lid is open.
    public var onlyWhenLidClosed: Bool
    /// The case rule. Nil from apps older than the rule, which then does not apply.
    public var caseRamp: CaseRamp?

    public init(points: [FanPoint], onlyWhenLidClosed: Bool = true, caseRamp: CaseRamp? = nil) {
        self.points = points
        self.onlyWhenLidClosed = onlyWhenLidClosed
        self.caseRamp = caseRamp
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
        copy.caseRamp = caseRamp?.clamped()
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

    /// The speed in percent the fans run at: the highest of the curve, the safety floor and the case rule
    /// (at `caseTemperature`, when there is one); 0 when off.
    public func speed(at temperature: Double, caseTemperature: Double? = nil) -> Double {
        guard !isOff else { return 0 }
        let forCase = caseTemperature.flatMap { celsius in caseRamp.map { $0.speed(at: celsius) } } ?? 0
        let wanted = max(curveSpeed(at: temperature), SafetyFloor.speed(at: temperature), forCase)
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
    // The curve starts early on purpose: a closed Mac in a bag has little airflow, and staying cool matters more than
    // quiet. At idle the hottest sensor sits a little above 40 °C, so the fans run a little above their minimum.
    public static let defaultStart = 40
    public static let defaultFull = 70

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
