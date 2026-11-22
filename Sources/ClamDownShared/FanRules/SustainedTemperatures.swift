import Foundation

/// The sensor group values the curve and the safety floor follow: each chip (CPU, GPU) as the die zone the SMC's own
/// fan controller steers by, averaged over about half a minute; every other group as read.
///
/// Why: the owner heard the fans roar at every 5–10 s burst while the Mac as a whole did not warm, and asked to compute
/// the temperature "примерно так же, как эпл" but to start the fans more eagerly, with a Mac in a bag in mind (owner,
/// 2026-11-22). Measured on their M3 Pro, macOS steers by the die zones (the sensor adapter's `SensorKeys.zoneKeys`),
/// which run about 14 °C under the hottest core and barely move with a burst, but it leaves the fans off until a zone
/// nears its setpoint of about 76 °C and ignores a case at 49 °C. Offered the zones averaged over 30 s or the hottest
/// core averaged over 60 s, the owner picked "Apple zone, 30 s avg" (owner, 2026-11-22). ClamDown takes the same
/// input and stays more eager: its curve starts at 40 °C, and the battery, SSD, Wi-Fi and airflow groups, which
/// follow the case and warm slowly by themselves, count as read, so a Mac warming in a bag still reaches full speed.
/// The short average takes out what is left of a burst. On a Mac whose zones cannot be confirmed, a chip counts as
/// its hottest sensor averaged over a minute, which also ignores a burst but keeps the fans higher at idle.
/// A core at its limit is the hot-core watch's job, which reads the raw hottest core.
/// Not chosen (agent, 2026-11-22): the raw zones, which still lift the fans by a third for a heavy 10 s burst; a
/// rolling minimum, which reads a load with short pauses as cool.
public struct SustainedTemperatures: Sendable {
    /// The groups whose values swing with load within seconds.
    public static let averagedGroups: Set<SensorGroup> = [.cpu, .gpu]
    /// After a step, an average covers 63 % of it in its time constant and 95 % in three times it.
    public static let zoneTimeConstant: Duration = .seconds(30)
    public static let hottestSensorTimeConstant: Duration = .seconds(60)

    private var averages: [SensorGroup: Double] = [:]
    private var updated: SuspendingClock.Instant?

    public init() {}

    /// Takes one reading and returns the groups as the curve follows them. A chip starts at its first value, so a
    /// session that begins during a burst starts high and falls back. A chip that switches between its zone and its
    /// hottest sensor keeps averaging, so the switch does not jump. A chip missing from the reading is forgotten
    /// and starts afresh when it comes back. Readings at the same instant leave the averages as they are.
    public mutating func update(groups: [SensorGroup: Double], zones: [SensorGroup: Double],
                                now: SuspendingClock.Instant) -> [SensorGroup: Double] {
        let elapsed = updated.map { max($0.duration(to: now), .zero) } ?? .zero
        updated = now
        var next: [SensorGroup: Double] = [:]
        for group in Self.averagedGroups {
            let zone = zones[group]
            guard let celsius = zone ?? groups[group] else { continue }
            let timeConstant = zone == nil ? Self.hottestSensorTimeConstant : Self.zoneTimeConstant
            let weight = 1 - exp(-(elapsed / timeConstant))
            next[group] = averages[group].map { $0 + (celsius - $0) * weight } ?? celsius
        }
        averages = next
        return applied(groups: groups, zones: zones)
    }

    /// The groups as the curve follows them, without taking a reading: each chip's average in place of its value.
    /// A chip without an average yet (no session running) counts as its zone, or as read when it has none.
    public func applied(groups: [SensorGroup: Double], zones: [SensorGroup: Double]) -> [SensorGroup: Double] {
        var followed = groups
        for group in Self.averagedGroups {
            followed[group] = averages[group] ?? zones[group] ?? groups[group]
        }
        return followed
    }
}
