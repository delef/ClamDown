public enum HelperError: Error, Equatable {
    case notEnabled
    /// `pmset -g` did not show a `SleepDisabled` value, so the user's setting cannot be restored later.
    case unreadableSleepSetting
}

/// The helper's whole job: switch `disablesleep` and the battery profile's Low Power Mode,
/// remember what to put back, and undo everything when asked.
public actor HelperCore {
    private let runner: PmsetRunning
    private let store: SavedStateStoring
    private let watchdogTimeout: Duration

    private var enabled = false
    /// Battery-profile Low Power Mode before we touched it. Nil means unreadable, so we never change it.
    private var priorBatteryLowPower: Bool?
    /// The user's own `SleepDisabled` value before we turned it on. Put back on every switch-off.
    private var priorSleepDisabled: Bool?
    private var lastHeartbeat: SuspendingClock.Instant = .now

    public init(runner: PmsetRunning, store: SavedStateStoring, watchdogTimeout: Duration = .seconds(90)) {
        self.runner = runner
        self.store = store
        self.watchdogTimeout = watchdogTimeout
    }

    public var isEnabled: Bool { enabled }

    public func enable(lowPowerOnBattery: Bool, now: SuspendingClock.Instant = .now) throws {
        if enabled {
            lastHeartbeat = now
            try applyLowPower(lowPowerOnBattery)
            return
        }
        let priorSleep = try readSleepDisabled()
        let prior = PmsetParser.batteryLowPowerMode(fromCustom: try runner.run(.readCustom))
        do {
            // Persist what to restore before anything changes, so a crash cannot lose it.
            try store.save(SavedState(batteryLowPowerMode: prior, sleepDisabled: priorSleep))
            try exec(.setSleepDisabled(true))
            if lowPowerOnBattery, prior != nil { try exec(.setBatteryLowPowerMode(true)) }
        } catch {
            try? exec(.setSleepDisabled(priorSleep))
            if let prior { try? exec(.setBatteryLowPowerMode(prior)) }
            try? store.clear()
            throw error
        }
        priorSleepDisabled = priorSleep
        priorBatteryLowPower = prior
        enabled = true
        lastHeartbeat = now
    }

    /// Always tries every step. On any failure the state is kept, so a retry can finish the job.
    public func disable() throws {
        var firstError: Error?
        do { try exec(.setSleepDisabled(priorSleepDisabled ?? false)) } catch { firstError = error }
        if let prior = priorBatteryLowPower {
            do { try exec(.setBatteryLowPowerMode(prior)) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
        try? store.clear()  // a stale file would only cause one needless restore on the next start
        priorSleepDisabled = nil
        priorBatteryLowPower = nil
        enabled = false
    }

    /// True while the mode is on; also pushes the watchdog deadline out.
    public func heartbeat(now: SuspendingClock.Instant = .now) -> Bool {
        guard enabled else { return false }
        lastHeartbeat = now
        return true
    }

    /// Resets the machine when no heartbeat arrived within the timeout. True when it did reset.
    /// A failed reset leaves the mode enabled, so the next tick tries again.
    /// `SuspendingClock` does not advance while the Mac sleeps, so a manual sleep is not a missed heartbeat.
    public func checkWatchdog(now: SuspendingClock.Instant = .now) -> Bool {
        guard enabled, lastHeartbeat.duration(to: now) > watchdogTimeout else { return false }
        do {
            try disable()
            return true
        } catch {
            return false
        }
    }

    public func setLowPowerOnBattery(_ on: Bool) throws {
        guard enabled else { throw HelperError.notEnabled }
        try applyLowPower(on)
    }

    /// Runs when the helper starts: puts back whatever a previous run left behind.
    public func recoverOnStart() throws {
        let saved = (try? store.load()) ?? nil
        var firstError: Error?
        if let lowPower = saved?.batteryLowPowerMode {
            do { try exec(.setBatteryLowPowerMode(lowPower)) } catch { firstError = error }
        }
        // Without a recorded value, fall back to the old behaviour: sleep allowed.
        do { try exec(.setSleepDisabled(saved?.sleepDisabled ?? false)) } catch { firstError = firstError ?? error }
        enabled = false
        priorSleepDisabled = nil
        priorBatteryLowPower = nil
        if let firstError { throw firstError }
        try? store.clear()
    }

    private func applyLowPower(_ on: Bool) throws {
        guard let prior = priorBatteryLowPower else { return }
        try exec(.setBatteryLowPowerMode(on ? true : prior))
    }

    private func readSleepDisabled() throws -> Bool {
        guard let value = PmsetParser.sleepDisabled(fromGlobal: try runner.run(.readGlobal)) else {
            throw HelperError.unreadableSleepSetting
        }
        return value
    }

    private func exec(_ command: PmsetCommand) throws {
        _ = try runner.run(command)
    }
}
