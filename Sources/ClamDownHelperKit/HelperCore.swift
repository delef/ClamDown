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
    private let lid: LidReading?
    private let idle: IdleReading?
    private let watchdogTimeout: Duration
    private let hardware: FanHardware?
    /// macOS's own thermal level, read by the helper itself. Nil leaves the system override off.
    private let thermal: ThermalStateReading?
    /// How far a fan's target may fall per `updateFans` call, in rpm.
    private let fanStepDown: Double

    private var enabled = false
    /// Battery-profile Low Power Mode before we touched it. Nil means unreadable, so we never change it.
    private var priorBatteryLowPower: Bool?
    /// The user's own `SleepDisabled` value before we turned it on. Put back on every switch-off.
    private var priorSleepDisabled: Bool?
    private var lastHeartbeat: SuspendingClock.Instant = .now
    private var owedSleep: OwedSleep?
    /// What is on disk, so fan changes can be added to it.
    private var saved: SavedState?

    /// The app's fan wishes for this session. Nil until the app sends them; dropped on switch-off.
    private var fanPolicy: FanPolicy?
    /// True from the moment ClamDown starts taking the fans until macOS has them back.
    private var fansHeld = false
    /// The speeds last set, in fan order. Nil while macOS has the fans.
    private var fanTargets: [Double]?
    /// Each fan's maximum from the last complete reading, for running held fans at full speed when a
    /// hand-back fails and the current reading misses a fan.
    private var knownFanMaxima: [Double]?
    /// Faults, retries and whether control has stopped. A new policy or Turn On starts it afresh.
    private var health = FanHealth()
    private var lagWatch = LagWatch()
    /// True while the helper is not asked to drive the fans: mode off, fan control off, no usable SMC,
    /// or the lid open with Only With Lid Closed. Not a fault.
    private var fanIdle = true
    /// Why the last hand-back to macOS failed, until one succeeds.
    private var releaseProblem: String?
    /// Watches for one core at its limit; reset whenever the helper is not asked to drive the fans.
    private var hotCore = HotCoreWatch()
    /// Why the fans last ran at full speed, while they did.
    private var fanOverride: FanOverride?

    public init(
        runner: PmsetRunning,
        store: SavedStateStoring,
        fans: FanHardware? = nil,
        lid: LidReading? = nil,
        idle: IdleReading? = nil,
        thermal: ThermalStateReading? = nil,
        watchdogTimeout: Duration = .seconds(90),
        fanStepDown: Double = 150
    ) {
        self.runner = runner
        self.store = store
        self.hardware = fans
        self.lid = lid
        self.idle = idle
        self.thermal = thermal
        self.watchdogTimeout = watchdogTimeout
        self.fanStepDown = fanStepDown
    }

    public var isEnabled: Bool { enabled }

    public func enable(lowPowerOnBattery: Bool, now: SuspendingClock.Instant = .now) throws {
        // The app is back, so the sleep an earlier watchdog switch-off owed is off.
        owedSleep = nil
        // A new Turn On: fan control starts afresh.
        health.restart()
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
        health.restart()
        fanIdle = true
        hotCore = HotCoreWatch()
        fanOverride = nil
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
        guard enabled else {
            sleepIfOwed(now: now)
            return false
        }
        guard lastHeartbeat.duration(to: now) > watchdogTimeout else { return false }
        do {
            try disable()
        } catch {
            return false
        }
        owedSleep = OwedSleep(since: now)
        sleepIfOwed(now: now)
        return true
    }

    /// A sleep the watchdog still owes an abandoned Mac.
    private struct OwedSleep {
        let since: SuspendingClock.Instant
        var requests = 0
        var lastRequest: SuspendingClock.Instant?
    }

    static let sleepRequestLimit = 3
    /// One `pmset sleepnow` can be refused, so the next request follows when the Mac is still awake this much later.
    static let sleepRequestGap: Duration = .seconds(20)
    /// After this long the watchdog's switch-off is history, and a Mac that closes now is somebody's own business.
    static let owedSleepLifetime: Duration = .seconds(300)

    /// The app is gone, so nothing asks for this Mac to stay awake any more. Closed and quiet, it may be heating up
    /// or running flat in a bag: sleep now rather than when macOS gets to it. The helper cannot see displays, so the
    /// lid and the time since the last key press decide; anyone coming back cancels the sleep.
    /// A failed request changes nothing, because the sleep setting is already back.
    private func sleepIfOwed(now: SuspendingClock.Instant) {
        guard var owed = owedSleep else { return }
        guard owed.since.duration(to: now) <= Self.owedSleepLifetime else {
            owedSleep = nil
            return
        }
        switch Attendance(lid: lid?.lid(), idle: idle?.idleTime(), externalDisplay: false) {
        case .attended:
            owedSleep = nil
        case .leaving:
            break
        case .unattended:
            if let last = owed.lastRequest, last.duration(to: now) < Self.sleepRequestGap { return }
            _ = try? runner.run(.sleepNow)
            owed.requests += 1
            owed.lastRequest = now
            owedSleep = owed.requests < Self.sleepRequestLimit ? owed : nil
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

    /// Stores the app's fan wishes for this session and applies them at once. A new policy starts afresh,
    /// even after fan control has stopped.
    public func setFanPolicy(_ policy: FanPolicy, now: SuspendingClock.Instant = .now) throws {
        guard enabled else { throw HelperError.notEnabled }
        fanPolicy = policy.repaired()
        health.restart()
        updateFans(now: now)
    }

    /// Call every few seconds. Sets the fan speeds while the mode is on and the policy asks for it;
    /// in every other case it hands the fans back to macOS if ClamDown holds them.
    /// The curve and the safety floor follow the average CPU temperature; a core at its limit or a Mac that
    /// macOS reports as hot runs the fans at full speed instead.
    /// Any fault (a failed read or write, a lost temperature, a fan that drops out of the reading or does not
    /// follow its target) hands the fans back to macOS; `FanHealth` says when to take them again.
    public func updateFans(now: SuspendingClock.Instant = .now) {
        guard enabled, let policy = fanPolicy, !policy.isOff else {
            hotCore = HotCoreWatch()
            stopDriving()
            return
        }
        guard let hardware, hardware.supportsControl else {
            // `coolingStatus` reports why; there is nothing to retry.
            stopDriving()
            return
        }
        let reading: HardwareReading
        do {
            reading = try hardware.read()
        } catch {
            fanIdle = false
            if health.mayTry(now: now) {
                fault("Could not read the sensors: \(error)", now: now)
            } else {
                releaseFansIfHeld()
            }
            return
        }
        let hotCoreActive = hotCore.update(hottest: reading.hottestCPUTemperature, now: now)
        if policy.onlyWhenLidClosed, reading.lidClosed != true {
            stopDriving()
            return
        }
        fanIdle = false
        // While a retry waits, a hand-back that failed is tried again on every tick.
        guard health.mayTry(now: now) else {
            fanOverride = nil
            releaseFansIfHeld()
            return
        }
        // `setTargets` writes by position and every fan needs a target, so every fan the hardware has must be
        // in the reading, in SMC order; otherwise a target could land on the wrong fan or a fan get none.
        guard isComplete(reading, hardware) else {
            fault(reading.fans.isEmpty ? "Could not read the fans." : "Could not read every fan.", now: now)
            return
        }
        knownFanMaxima = reading.fans.map(\.maximum)
        // Without a temperature the curve cannot work, and guessing is worse than macOS's own control.
        guard let temperature = reading.cpuTemperature else {
            fault("Cannot read the CPU temperature.", now: now)
            return
        }
        if fansHeld, let previous = fanTargets,
           let lagging = lagWatch.update(targets: previous, fans: reading.fans, now: now) {
            fault("Fan \(lagging + 1) does not reach the speed it was set to.", now: now)
            return
        }
        let override: FanOverride? = if hotCoreActive {
            .hotCore
        } else if let level = thermal?.thermalLevel(), level >= .serious {
            .system
        } else {
            nil
        }
        let percent = override == nil ? policy.speed(at: temperature) : 100
        let targets = reading.fans.enumerated().map { index, fan in
            let wanted = FanCurve.speed(percent: percent, fan: fan)
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
            fanOverride = override
            health.tickHeld(now: now)
        } catch {
            fault("Could not set the fan speed: \(error)", now: now)
        }
    }

    /// What the helper sees and does right now. Reads the sensors but changes nothing.
    public func coolingStatus() -> CoolingStatus {
        let reading = try? hardware?.read()
        let control: FanControlState = fanIdle ? .idle : health.state
        let problem: String? = if hardware == nil {
            "Cannot open the SMC."
        } else if hardware?.supportsControl == false {
            FanHardwareError.unsupported.description
        } else if let releaseProblem {
            releaseProblem
        } else if control == .retrying || control == .stopped {
            health.reason
        } else {
            nil
        }
        return CoolingStatus(
            cpuTemperature: reading?.cpuTemperature,
            hottestCPUTemperature: reading?.hottestCPUTemperature,
            fans: reading?.fans ?? [],
            isControlling: fansHeld,
            problem: problem,
            override: fansHeld ? fanOverride : nil,
            control: control,
            systemThermalLevel: thermal?.thermalLevel()
        )
    }

    /// Not asked to drive the fans (not a fault): hand them back and wait.
    private func stopDriving() {
        fanIdle = true
        fanOverride = nil
        health.pause()
        releaseFansIfHeld()
    }

    /// Hands the fans to macOS after a fault; `health` decides when to take them again.
    private func fault(_ reason: String, now: SuspendingClock.Instant) {
        fanOverride = nil
        lagWatch = LagWatch()
        releaseFansIfHeld()
        health.fault(reason, now: now)
    }

    /// True when the reading holds every fan the hardware has, each at its own SMC index.
    private func isComplete(_ reading: HardwareReading, _ hardware: FanHardware) -> Bool {
        !reading.fans.isEmpty && reading.fans.count == hardware.fanCount
            && reading.fans.enumerated().allSatisfy { position, fan in fan.index.map { $0 == position } ?? true }
    }

    /// Hands the fans back to macOS. A failure keeps `fansHeld`, so the next call tries again, and runs the
    /// fans at full speed meanwhile: nothing drives them while ClamDown is not in control, and a fan left at
    /// its last target could stay slow on a Mac that is heating up.
    private func releaseFansIfHeld() {
        guard fansHeld, let hardware else { return }
        do {
            try hardware.releaseFans()
        } catch {
            releaseProblem = "Could not hand the fans back to macOS: \(error)"
            runHeldFansAtMaximum(hardware)
            return
        }
        releaseProblem = nil
        fansHeld = false
        fanTargets = nil
        lagWatch = LagWatch()
        if enabled {
            try? recordFansHeld(false)
        } else if saved == SavedState(fansManual: true) {
            // Left behind by a switch-off whose fan release failed; nothing else is left to restore.
            try? store.clear()
            saved = nil
        }
    }

    /// Best effort: sets every fan still in manual mode to its maximum. A fan macOS already has is left to macOS:
    /// taking it back could block the tick for seconds and fight macOS on every tick.
    /// The take-over stays on disk, because the fans are still held.
    private func runHeldFansAtMaximum(_ hardware: FanHardware) {
        let maxima: [Double]?
        if let reading = try? hardware.read(), isComplete(reading, hardware) {
            maxima = reading.fans.map(\.maximum)
        } else {
            maxima = knownFanMaxima
        }
        guard let maxima, maxima.count == hardware.fanCount else { return }
        do {
            try hardware.setTargetsIfHeld(maxima)
            fanTargets = maxima
        } catch {
            // The hand-back is retried on the next tick, and this with it.
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
