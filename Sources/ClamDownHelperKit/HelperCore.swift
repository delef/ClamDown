import ClamDownSensors
import ClamDownShared

public enum HelperError: Error, Equatable {
    case notEnabled
    /// `pmset -g` did not show a `SleepDisabled` value, so the user's setting cannot be restored later.
    case unreadableSleepSetting
}

/// The helper's whole job: switch `disablesleep` and the battery profile's Low Power Mode,
/// drive the fans while the mode is on, remember what to put back, and undo everything when asked.
public actor HelperCore {
    private let runner: PmsetRunning
    private let store: SavedStateStoring
    private let watchdogTimeout: Duration
    private let hardware: FanHardware?
    /// How far a fan's target may fall per `updateFans` call, in rpm.
    private let fanStepDown: Double

    private var enabled = false
    /// Battery-profile Low Power Mode before we touched it. Nil means unreadable, so we never change it.
    private var priorBatteryLowPower: Bool?
    /// The user's own `SleepDisabled` value before we turned it on. Put back on every switch-off.
    private var priorSleepDisabled: Bool?
    private var lastHeartbeat: SuspendingClock.Instant = .now
    /// What is on disk, so fan changes can be added to it.
    private var saved: SavedState?

    /// The app's fan wishes for this session. Nil until the app sends them; dropped on switch-off.
    private var fanPolicy: FanPolicy?
    /// True from the moment ClamDown starts taking the fans until macOS has them back.
    private var fansHeld = false
    /// The speeds last set, in fan order. Nil while macOS has the fans.
    private var fanTargets: [Double]?
    /// Set after a failed take-over, so the helper does not retry every tick. A new policy clears it.
    private var fanControlFailed = false
    private var fanProblem: String?

    public init(
        runner: PmsetRunning,
        store: SavedStateStoring,
        fans: FanHardware? = nil,
        watchdogTimeout: Duration = .seconds(90),
        fanStepDown: Double = 150
    ) {
        self.runner = runner
        self.store = store
        self.hardware = fans
        self.watchdogTimeout = watchdogTimeout
        self.fanStepDown = fanStepDown
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
            let state = SavedState(batteryLowPowerMode: prior, sleepDisabled: priorSleep, fansManual: fansHeld ? true : nil)
            try store.save(state)
            saved = state
            try exec(.setSleepDisabled(true))
            if lowPowerOnBattery, prior != nil { try exec(.setBatteryLowPowerMode(true)) }
        } catch {
            try? exec(.setSleepDisabled(priorSleep))
            if let prior { try? exec(.setBatteryLowPowerMode(prior)) }
            try? store.clear()
            saved = nil
            throw error
        }
        priorSleepDisabled = priorSleep
        priorBatteryLowPower = prior
        enabled = true
        lastHeartbeat = now
    }

    /// Always tries every step. On any sleep or Low Power Mode failure the state is kept, so a retry can finish the job.
    /// Fans that cannot be handed back do not block the switch-off: `updateFans` keeps retrying,
    /// and the saved state makes the next helper start retry too.
    public func disable() throws {
        releaseFansIfHeld()
        var firstError: Error?
        do { try exec(.setSleepDisabled(priorSleepDisabled ?? false)) } catch { firstError = error }
        if let prior = priorBatteryLowPower {
            do { try exec(.setBatteryLowPowerMode(prior)) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
        if fansHeld {
            let state = SavedState(fansManual: true)
            try? store.save(state)
            saved = state
        } else {
            try? store.clear()  // a stale file would only cause one needless restore on the next start
            saved = nil
        }
        priorSleepDisabled = nil
        priorBatteryLowPower = nil
        fanPolicy = nil
        fanControlFailed = false
        fanProblem = nil
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
        var fansStillHeld = false
        if saved?.fansManual == true, let hardware {
            do { try hardware.releaseFans() } catch { firstError = error; fansStillHeld = true }
        }
        if let lowPower = saved?.batteryLowPowerMode {
            do { try exec(.setBatteryLowPowerMode(lowPower)) } catch { firstError = error }
        }
        // Without a recorded value, fall back to the old behaviour: sleep allowed.
        do { try exec(.setSleepDisabled(saved?.sleepDisabled ?? false)) } catch { firstError = firstError ?? error }
        enabled = false
        priorSleepDisabled = nil
        priorBatteryLowPower = nil
        fansHeld = fansStillHeld  // lets `updateFans` keep trying to hand them back
        fanTargets = nil
        if let firstError { throw firstError }
        try? store.clear()
        self.saved = nil
    }

    // MARK: - Fans

    /// Stores the app's fan wishes for this session and applies them at once.
    public func setFanPolicy(_ policy: FanPolicy) throws {
        guard enabled else { throw HelperError.notEnabled }
        fanPolicy = policy.clamped()
        fanControlFailed = false
        fanProblem = nil
        updateFans()
    }

    /// Call every few seconds. Sets the fan speeds while the mode is on and the policy asks for it;
    /// in every other case it hands the fans back to macOS if ClamDown holds them.
    public func updateFans() {
        guard enabled, let policy = fanPolicy, policy.mode != .system else {
            releaseFansIfHeld()
            return
        }
        guard let hardware else {
            fanProblem = "Cannot open the SMC."
            return
        }
        guard hardware.supportsControl else {
            fanProblem = FanHardwareError.unsupported.description
            return
        }
        guard !fanControlFailed else { return }
        let reading: HardwareReading
        do {
            reading = try hardware.read()
        } catch {
            fanProblem = "Could not read the sensors: \(error)"
            releaseFansIfHeld()
            return
        }
        if policy.onlyWhenLidClosed, reading.lidClosed != true {
            fanProblem = nil
            releaseFansIfHeld()
            return
        }
        guard !reading.fans.isEmpty else {
            fanProblem = "This Mac has no fans."
            return
        }
        // Without a temperature the curve cannot work, and guessing is worse than macOS's own control.
        guard let temperature = reading.cpuTemperature else {
            fanProblem = "Cannot read the CPU temperature."
            releaseFansIfHeld()
            return
        }
        let targets = reading.fans.enumerated().map { index, fan in
            let wanted = FanCurve.speed(at: temperature, policy: policy, fan: fan)
            let previous = fanTargets.flatMap { index < $0.count ? $0[index] : nil }
            let smoothed = FanCurve.smoothed(previous: previous, wanted: wanted, maxDrop: fanStepDown)
            return min(max(smoothed, fan.minimum), fan.maximum)
        }
        do {
            if !fansHeld {
                // Record the take-over before touching the fans, so a crash cannot leave them stuck.
                try recordFansHeld(true)
                fansHeld = true
            }
            try hardware.setTargets(targets)
            fanTargets = targets
            fanProblem = nil
        } catch {
            fanProblem = "Could not set the fan speed: \(error)"
            fanControlFailed = true
            releaseFansIfHeld()
        }
    }

    public func coolingStatus() -> CoolingStatus {
        let reading = try? hardware?.read()
        var problem = fanProblem
        if hardware == nil {
            problem = "Cannot open the SMC."
        } else if hardware?.supportsControl == false {
            problem = FanHardwareError.unsupported.description
        }
        return CoolingStatus(
            cpuTemperature: reading?.cpuTemperature,
            fans: reading?.fans ?? [],
            isControlling: fansHeld,
            problem: problem
        )
    }

    /// Hands the fans back to macOS. A failure keeps `fansHeld`, so the next call tries again.
    private func releaseFansIfHeld() {
        guard fansHeld, let hardware else { return }
        do {
            try hardware.releaseFans()
        } catch {
            fanProblem = "Could not hand the fans back to macOS: \(error)"
            return
        }
        fansHeld = false
        fanTargets = nil
        if enabled {
            try? recordFansHeld(false)
        } else if saved == SavedState(fansManual: true) {
            // Left behind by a switch-off whose fan release failed; nothing else is left to restore.
            try? store.clear()
            saved = nil
        }
    }

    private func recordFansHeld(_ held: Bool) throws {
        var state = saved ?? SavedState()
        state.fansManual = held ? true : nil
        try store.save(state)
        saved = state
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
