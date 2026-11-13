import ClamDownShared

public enum FanCurve {
    /// The speed (rpm) the policy wants for one fan at this CPU temperature: the policy's percent
    /// (curve or safety floor, whichever is higher) scaled to the fan's own minimum and maximum.
    public static func speed(at temperature: Double, policy: FanPolicy, fan: FanReading) -> Double {
        fan.minimum + (fan.maximum - fan.minimum) * policy.speed(at: temperature) / 100
    }

    /// Speeds rise at once but fall by at most `maxDrop` rpm per step, so a short dip in load does not make the fans hunt.
    public static func smoothed(previous: Double?, wanted: Double, maxDrop: Double) -> Double {
        guard let previous, wanted < previous else { return wanted }
        return max(wanted, previous - maxDrop)
    }
}
