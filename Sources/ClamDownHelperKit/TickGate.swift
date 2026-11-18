import Foundation

/// Runs one periodic tick at a time. A tick that arrives while the previous one is still running is skipped,
/// not queued, so a slow tick (an SMC call waiting for macOS) cannot build a backlog that delays the app's
/// heartbeats behind it on the helper's actor.
public final class TickGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var skipped = 0

    public init() {}

    /// True while a tick runs.
    public var isBusy: Bool { lock.withLock { busy } }
    /// Ticks skipped in a row because the one before was still running. A tick that starts resets it.
    public var skippedInARow: Int { lock.withLock { skipped } }

    /// Starts `body` in a task unless the previous tick is still running. True when it started.
    @discardableResult
    public func start(_ body: @escaping @Sendable () async -> Void) -> Bool {
        let entered = lock.withLock {
            guard !busy else {
                skipped += 1
                return false
            }
            busy = true
            skipped = 0
            return true
        }
        guard entered else { return false }
        Task {
            await body()
            self.finish()
        }
        return true
    }

    private func finish() {
        lock.withLock { busy = false }
    }
}
