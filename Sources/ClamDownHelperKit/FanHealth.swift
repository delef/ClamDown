import ClamDownShared

/// Whether fan control is working, and when to try again after a fault.
///
/// A fault hands the fans to macOS (the caller does that) and the helper tries again after `retryAfter`.
/// `faultsToStop` faults in a row mean stopped: the helper then tries only every `stoppedRetryEvery`, and
/// returns to controlling once a try has held for `holdToRecover`. The count of faults goes back to zero only
/// after `quietReset` of control without a fault, so a fan that takes the write and lags again still counts.
///
/// Times come from `SuspendingClock`, which stands still while the Mac sleeps: a gap only means ticks were
/// missed, and the next tick acts once.
public struct FanHealth: Sendable {
    // First guesses from the spec; device measurements may change them, keeping the rules' shape.
    public static let defaultRetryAfter: Duration = .seconds(30)
    public static let defaultFaultsToStop = 3
    public static let defaultQuietReset: Duration = .seconds(60)
    public static let defaultStoppedRetryEvery: Duration = .seconds(300)
    public static let defaultHoldToRecover: Duration = .seconds(60)

    private let retryAfter: Duration
    private let faultsToStop: Int
    private let quietReset: Duration
    private let stoppedRetryEvery: Duration
    private let holdToRecover: Duration

    /// Controlling, retrying or stopped. Never idle: whether the helper is asked to control is the caller's to say.
    public private(set) var state: FanControlState = .controlling
    /// What the last fault was, while retrying or stopped.
    public private(set) var reason: String?
    private var faults = 0
    private var lastFault: SuspendingClock.Instant?
    /// When the current run of good ticks began.
    private var holdingSince: SuspendingClock.Instant?

    public init(retryAfter: Duration = defaultRetryAfter, faultsToStop: Int = defaultFaultsToStop,
                quietReset: Duration = defaultQuietReset, stoppedRetryEvery: Duration = defaultStoppedRetryEvery,
                holdToRecover: Duration = defaultHoldToRecover) {
        self.retryAfter = retryAfter
        self.faultsToStop = faultsToStop
        self.quietReset = quietReset
        self.stoppedRetryEvery = stoppedRetryEvery
        self.holdToRecover = holdToRecover
    }

    /// The fans were handed back to macOS because of `reason`.
    public mutating func fault(_ reason: String, now: SuspendingClock.Instant) {
        faults += 1
        self.reason = reason
        lastFault = now
        holdingSince = nil
        state = faults >= faultsToStop ? .stopped : .retrying
    }

    /// A tick on which the targets were written and every fan kept up.
    public mutating func tickHeld(now: SuspendingClock.Instant) {
        let since = holdingSince ?? now
        holdingSince = since
        let held = since.duration(to: now)
        if held >= quietReset { faults = 0 }
        switch state {
        case .retrying, .idle:
            state = .controlling
            reason = nil
        case .stopped where held >= holdToRecover:
            state = .controlling
            reason = nil
        case .stopped, .controlling:
            break
        }
    }

    /// The helper stopped driving the fans for a reason that is not a fault (lid open, fan control off).
    /// That time is not control without a fault, so the quiet minute starts again.
    public mutating func pause() {
        holdingSince = nil
    }

    /// True when the helper may take the fans now.
    public func mayTry(now: SuspendingClock.Instant) -> Bool {
        guard let lastFault else { return true }
        switch state {
        case .controlling, .idle: return true
        case .retrying: return lastFault.duration(to: now) >= retryAfter
        case .stopped: return lastFault.duration(to: now) >= stoppedRetryEvery
        }
    }

    /// A new policy or a new Turn On: start afresh, and try at once.
    public mutating func restart() {
        state = .controlling
        reason = nil
        faults = 0
        lastFault = nil
        holdingSince = nil
    }
}

/// Finds a fan that does not follow its target: more than `fraction` of its range below the target on
/// `ticks` readings in a row. Running faster than the target is fine. A fan without a range (maximum not above
/// minimum, as some sensors report) is never judged.
public struct LagWatch: Sendable {
    // First guesses from the spec; device measurements may change them, keeping the rule's shape.
    public static let defaultFraction = 0.2
    /// Five ticks of 3 seconds: 15 seconds.
    public static let defaultTicks = 5

    private let fraction: Double
    private let ticks: Int
    private var counts: [Int] = []

    public init(fraction: Double = defaultFraction, ticks: Int = defaultTicks) {
        self.fraction = fraction
        self.ticks = ticks
    }

    /// Compares each fan's speed now with the target it was last given. Returns the index of a fan that has
    /// lagged for `ticks` readings in a row, or nil. Lists of different lengths are not judged.
    public mutating func update(targets: [Double], fans: [FanReading]) -> Int? {
        guard targets.count == fans.count else {
            counts = []
            return nil
        }
        if counts.count != fans.count { counts = Array(repeating: 0, count: fans.count) }
        var lagging: Int?
        for (index, fan) in fans.enumerated() {
            let range = fan.maximum - fan.minimum
            guard range > 0, fan.rpm < targets[index] - range * fraction else {
                counts[index] = 0
                continue
            }
            counts[index] += 1
            if counts[index] >= ticks, lagging == nil { lagging = index }
        }
        return lagging
    }
}
