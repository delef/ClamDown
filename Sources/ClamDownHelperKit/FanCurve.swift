import ClamDownShared

public enum FanCurve {
    /// The speed (rpm) the policy wants for one fan at this CPU temperature.
    /// The curve runs in a straight line from the fan's minimum at the start point to its maximum at the full-speed point.
    public static func speed(at temperature: Double, policy: FanPolicy, fan: FanReading) -> Double {
        switch policy.mode {
        case .system:
            return fan.minimum
        case .fullSpeed:
            return fan.maximum
        case .curve:
            let start = Double(policy.startTemperature)
            let full = Double(policy.fullSpeedTemperature)
            let fraction = full > start ? min(max((temperature - start) / (full - start), 0), 1) : 1
            return fan.minimum + (fan.maximum - fan.minimum) * fraction
        }
    }

    /// Speeds rise at once but fall by at most `maxDrop` rpm per step, so a short dip in load does not make the fans hunt.
    public static func smoothed(previous: Double?, wanted: Double, maxDrop: Double) -> Double {
        guard let previous, wanted < previous else { return wanted }
        return max(wanted, previous - maxDrop)
    }
}
