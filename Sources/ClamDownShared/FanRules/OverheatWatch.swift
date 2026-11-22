import Foundation

/// Watches one temperature for a part that runs too hot, which the curve alone may not answer in time.
/// On after the value has stayed at or above `onAt` for `onAfter`; off after it has stayed below `offBelow`
/// for `offAfter`. A missing reading counts as cool, so a Mac without the value never goes to full speed for
/// this reason.
public struct OverheatWatch: Sendable {
    /// The hottest CPU core pinned at its limit, which the average hides among idle cores.
    /// First guesses from the spec; device measurements may change them, keeping the rule's shape.
    public static func hotCore() -> OverheatWatch {
        OverheatWatch(onAt: 100, onAfter: .seconds(10), offBelow: 95, offAfter: .seconds(30))
    }

    /// The hottest battery sensor: a battery warms slowly and suffers from heat, so full speed comes at once.
    public static func hotBattery() -> OverheatWatch {
        OverheatWatch(onAt: 45, onAfter: .zero, offBelow: 43, offAfter: .seconds(30))
    }

    private let onAt: Double
    private let onAfter: Duration
    private let offBelow: Double
    private let offAfter: Duration

    public private(set) var isActive = false
    /// When the current run of hot readings began, while not active.
    private var hotSince: SuspendingClock.Instant?
    /// When the current run of cool readings began, while active.
    private var coolSince: SuspendingClock.Instant?

    public init(onAt: Double, onAfter: Duration, offBelow: Double, offAfter: Duration) {
        self.onAt = onAt
        self.onAfter = onAfter
        self.offBelow = offBelow
        self.offAfter = offAfter
    }

    /// Takes one reading and returns whether the override is on.
    public mutating func update(hottest: Double?, now: SuspendingClock.Instant) -> Bool {
        if isActive {
            hotSince = nil
            let cool = hottest.map { $0 < offBelow } ?? true
            guard cool else {
                coolSince = nil
                return true
            }
            let since = coolSince ?? now
            coolSince = since
            if since.duration(to: now) >= offAfter {
                isActive = false
                coolSince = nil
            }
        } else {
            coolSince = nil
            guard let hottest, hottest >= onAt else {
                hotSince = nil
                return false
            }
            let since = hotSince ?? now
            hotSince = since
            if since.duration(to: now) >= onAfter {
                isActive = true
                hotSince = nil
            }
        }
        return isActive
    }
}
