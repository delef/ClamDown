import ClamDownShared

/// Watches the hottest CPU core for one pinned at its limit, which the average hides among idle cores.
/// On after the hottest core has stayed at or above `onAt` for `onAfter`; off after it has stayed below
/// `offBelow` for `offAfter`. A missing reading counts as cool, so a Mac without a hottest-core value
/// never goes to full speed for this reason.
public struct HotCoreWatch: Sendable {
    // First guesses from the spec; device measurements may change them, keeping the rule's shape.
    public static let defaultOnAt: Double = 100
    public static let defaultOnAfter: Duration = .seconds(10)
    public static let defaultOffBelow: Double = 95
    public static let defaultOffAfter: Duration = .seconds(30)

    private let onAt: Double
    private let onAfter: Duration
    private let offBelow: Double
    private let offAfter: Duration

    public private(set) var isActive = false
    /// When the current run of hot readings began, while not active.
    private var hotSince: SuspendingClock.Instant?
    /// When the current run of cool readings began, while active.
    private var coolSince: SuspendingClock.Instant?

    public init(onAt: Double = defaultOnAt, onAfter: Duration = defaultOnAfter,
                offBelow: Double = defaultOffBelow, offAfter: Duration = defaultOffAfter) {
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
