import ClamDownShared

/// The rules for editing the fan curves on the Cooling page, kept apart from the view so they can be tested.
public enum FanCurveEditor {
    /// Five points on the Standard line from `start` to `full`, evenly spaced by temperature, at 0, 25, 50, 75
    /// and 100 %. Choosing Advanced with these points changes nothing until a point is dragged.
    /// Rounding the temperatures can put a point a little inside the safety floor near its edge (70/95), so each
    /// speed is raised to the floor at its temperature; the floor rises with temperature, so the speeds stay in order.
    public static func advanced(fromStart start: Int, full: Int) -> [FanPoint] {
        (0..<advancedPointCount).map { step in
            let fraction = Double(step) / Double(advancedPointCount - 1)
            let temperature = Int((Double(start) + Double(full - start) * fraction).rounded(.toNearestOrAwayFromZero))
            return FanPoint(temperature: temperature, speed: max(step * 25, floorSpeed(at: temperature)))
        }
    }

    /// Advanced always has exactly this many points; a stored list of another length counts as absent.
    public static let advancedPointCount = 5

    public static let defaultAdvanced = advanced(fromStart: StandardCurve.defaultStart, full: StandardCurve.defaultFull)

    /// Moves one Standard point (0 = "speeds up from", 1 = "full speed at") sideways to `temperature`.
    /// It stays in its range and stops 5 °C short of the other point; the other point never moves.
    public static func movedStandard(start: Int, full: Int, dragging index: Int, to temperature: Int)
        -> (start: Int, full: Int) {
        if index == 0 {
            let limit = min(StandardCurve.startRange.upperBound, full - StandardCurve.minimumSpan)
            return (max(min(temperature, limit), StandardCurve.startRange.lowerBound), full)
        }
        let lowest = max(start + StandardCurve.minimumSpan, StandardCurve.startRange.lowerBound + StandardCurve.minimumSpan)
        return (start, max(min(temperature, StandardCurve.fullSpeedMaximum), lowest))
    }

    /// Moves one Advanced point towards `target`. The point stops, and never pushes, at the point before it
    /// (not left of it, not below it) and the point after it (not right of it, not above it). Its speed stays at
    /// or above the safety floor, and it does not go so far right that the floor there would be above the
    /// next point's speed.
    public static func movedAdvanced(_ points: [FanPoint], dragging index: Int, to target: FanPoint) -> [FanPoint] {
        guard points.indices.contains(index) else { return points }
        let previous = index > points.startIndex ? points[index - 1] : nil
        let next = index + 1 < points.endIndex ? points[index + 1] : nil
        let temperatures = FanPolicy.temperatureRange, speeds = FanPolicy.speedRange

        var temperature = min(max(target.temperature, temperatures.lowerBound), temperatures.upperBound)
        if let next {
            temperature = min(temperature, next.temperature, hottestBelowFloor(speed: next.speed))
        }
        if let previous { temperature = max(temperature, previous.temperature) }

        var speed = min(max(target.speed, speeds.lowerBound), speeds.upperBound)
        if let next { speed = min(speed, next.speed) }
        if let previous { speed = max(speed, previous.speed) }
        speed = max(speed, floorSpeed(at: temperature))

        var moved = points
        moved[index] = FanPoint(temperature: temperature, speed: speed)
        return moved
    }

    /// Switches to Advanced. The first time, its points are placed on the current Standard line; later times
    /// keep the points the user left.
    public static func chooseAdvanced(_ settings: Settings) -> Settings {
        var copy = settings
        copy.fanCurveMode = .advanced
        if copy.fanAdvancedPoints?.count != advancedPointCount {
            let line = StandardCurve.clamped(start: settings.fanStartTemperature, full: settings.fanFullSpeedTemperature)
            copy.fanAdvancedPoints = advanced(fromStart: line.start, full: line.full)
        }
        return copy
    }

    /// Puts the visible mode back to its defaults and leaves the other one alone.
    public static func reset(_ settings: Settings) -> Settings {
        var copy = settings
        switch settings.fanCurveMode {
        case .standard:
            copy.fanStartTemperature = StandardCurve.defaultStart
            copy.fanFullSpeedTemperature = StandardCurve.defaultFull
        case .advanced:
            copy.fanAdvancedPoints = defaultAdvanced
        }
        return copy
    }

    /// The safety floor at a whole temperature, as a whole percent, rounded up so a point never sits under it.
    private static func floorSpeed(at temperature: Int) -> Int {
        Int(SafetyFloor.speed(at: Double(temperature)).rounded(.up))
    }

    /// The highest whole temperature at which the safety floor is still at or below `speed`.
    private static func hottestBelowFloor(speed: Int) -> Int {
        let range = FanPolicy.temperatureRange
        return range.reversed().first { floorSpeed(at: $0) <= speed } ?? range.lowerBound
    }
}
