import Foundation
import ClamDownSensors
import ClamDownShared

public enum HelperError: Error, Equatable, CustomStringConvertible {
    case notEnabled
    /// `pmset -g` did not show a `SleepDisabled` value, so the user's setting cannot be restored later.
    case unreadableSleepSetting
    /// The fans could not be handed back to macOS, so the original settings are not put back yet.
    case fansStillHeld

    /// The text the app shows. No final period: the app adds its own.
    public var description: String {
        switch self {
        case .notEnabled: "The mode is not on"
        case .unreadableSleepSetting: "pmset did not report the sleep setting"
        case .fansStillHeld: "ClamDown could not hand the fans back to macOS"
        }
    }
}

/// The helper's whole job: switch `disablesleep` and the battery profile's Low Power Mode,
/// drive the fans while the mode is on, remember what to put back, and undo everything when asked.
public actor HelperCore {
    private let runner: PmsetRunning
    private let store: SavedStateStoring
    private let originals: OriginalSettingsStoring
    private let lid: LidReading?
    private let idle: IdleReading?
    private let watchdogTimeout: Duration
    private let hardware: FanHardware?
    /// macOS's own thermal level, read by the helper itself. Nil leaves the system override off.
    private let thermal: ThermalStateReading?
    /// How far a fan's target may fall per `fanStepInterval`, in rpm. The fall is limited by time, not by call:
    /// a new policy runs `updateFans` at once, and a burst of them must not drop the fans faster.
    private let fanStepDown: Double
    private let fanStepInterval: Duration

    private var enabled = false
    /// The app connection that switched the mode on, while it is on.
    private var owner: UUID?
    /// True once launchd is stopping the helper: the fans are never taken again.
    private var terminating = false
    /// True once a reading had a CPU temperature. Losing it later is a fault: the other groups run far cooler.
    private var cpuSeen = false
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
    /// When `fanTargets` were last written by `updateFans`; the allowed fall grows with the time since.
    private var fanTargetsWritten: SuspendingClock.Instant?
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
    private var hotCore = OverheatWatch.hotCore()
    /// Watches the hottest battery sensor; reset with `hotCore`.
    private var hotBattery = OverheatWatch.hotBattery()
    /// Why the fans last ran at full speed, while they did.
    private var fanOverride: FanOverride?

    public init(
        runner: PmsetRunning,
        store: SavedStateStoring,
        originals: OriginalSettingsStoring,
        fans: FanHardware? = nil,
        lid: LidReading? = nil,
        idle: IdleReading? = nil,
        thermal: ThermalStateReading? = nil,
        watchdogTimeout: Duration = .seconds(90),
        fanStepDown: Double = 150,
        fanStepInterval: Duration = .seconds(3)
    ) {
        self.runner = runner
        self.store = store
        self.originals = originals
        self.hardware = fans
        self.lid = lid
        self.idle = idle
        self.thermal = thermal
        self.watchdogTimeout = watchdogTimeout
        self.fanStepDown = fanStepDown
        self.fanStepInterval = fanStepInterval
    }

    public var isEnabled: Bool { enabled }

    /// `owner` is the app connection that asked; see `connectionClosed`. Nil for callers without one.
    public func enable(lowPowerOnBattery: Bool, owner: UUID? = nil, now: SuspendingClock.Instant = .now) throws {
        // The app is back, so the sleep an earlier watchdog switch-off owed is off.
        owedSleep = nil
        // A new Turn On: fan control starts afresh.
        health.restart()
        if enabled {
            lastHeartbeat = now
            self.owner = owner
            try applyLowPower(lowPowerOnBattery)
            return
        }
        // A session that was never undone (its recovery on start failed) left the user's values on disk; the current
        // ones may still be ClamDown's, so they must not become the values to put back.
        let pending = (try? store.load()) ?? nil
        let priorSleep: Bool
        let prior: Bool?
        if let pending, let pendingSleep = pending.sleepDisabled {
            priorSleep = pendingSleep
            prior = pending.batteryLowPowerMode
        } else {
            priorSleep = try readSleepDisabled()
            prior = PmsetParser.batteryLowPowerMode(fromCustom: try runner.run(.readCustom))
        }
        let clean = pending?.sleepDisabled == nil
        do {
            // Persist what to restore before anything changes, so a crash cannot lose it.
            let state = SavedState(batteryLowPowerMode: prior, sleepDisabled: priorSleep, fansManual: fansHeld ? true : nil)
            try store.save(state)
            saved = state
            try recordOriginalSettings(sleepDisabled: priorSleep, batteryLowPowerMode: prior, replacing: clean)
            try exec(.setSleepDisabled(true))
            if lowPowerOnBattery, prior != nil { try exec(.setBatteryLowPowerMode(true)) }
        } catch {
            try? exec(.setSleepDisabled(priorSleep))
            if let prior { try? exec(.setBatteryLowPowerMode(prior)) }
            // Fans whose hand-back failed earlier are still held, and the next start must know that.
            if fansHeld {
                let state = SavedState(fansManual: true)
                try? store.save(state)
                saved = state
            } else {
                try? store.clear()
                saved = nil
            }
            throw error
        }
        priorSleepDisabled = priorSleep
        priorBatteryLowPower = prior
        enabled = true
        self.owner = owner
        lastHeartbeat = now
    }

    /// An app connection closed (the app quit, crashed or dropped it). Switches off unless the mode belongs to a
    /// newer connection: an app that reconnected and switched on again must not lose the mode to its old connection.
    public func connectionClosed(_ connection: UUID) throws {
        if enabled, let owner, owner != connection { return }
        try disable()
    }

    /// launchd is stopping the helper. Nothing may take the fans again after this, whatever the switch-off does.
    public func shutdown() throws {
        terminating = true
        try disable()
    }

    /// Always tries every step. On any sleep or Low Power Mode failure the state is kept, so a retry can finish the job.
    /// Fans that cannot be handed back do not block the switch-off: `updateFans` keeps retrying,
    /// and the saved state makes the next helper start retry too.
    /// While the mode is off the sleep setting and Low Power Mode are the user's own and stay untouched; only a
    /// session left on disk by a failed recovery is put back, which makes this a retry of that recovery.
    public func disable() throws {
        releaseFansIfHeld()
        guard enabled else {
            try recoverOnStart()
            return
        }
        var firstError: Error?
        do { try exec(.setSleepDisabled(priorSleepDisabled ?? false)) } catch { firstError = error }
        if let prior = priorBatteryLowPower {
            do { try exec(.setBatteryLowPowerMode(prior)) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
        markSwitchedOff()
    }

    /// Puts back the values recorded before ClamDown first switched on, then deletes that record. Used before the helper
    /// is removed. The record stays when a step fails, so a retry can finish the job. Without a record this is `disable()`.
    /// An unreadable record counts as none and is deleted with the switch-off: it can never be put back.
    public func restoreOriginalSettings() throws {
        guard let original = (try? originals.load()) ?? nil else {
            try disable()
            try? originals.delete()
            return
        }
        releaseFansIfHeld()
        // Every step is tried. If the fans stay with ClamDown, the record and the saved state stay too, so a retry hands them back.
        var firstError: Error?
        if fansHeld { firstError = HelperError.fansStillHeld }
        do { try exec(.setSleepDisabled(original.sleepDisabled ?? false)) } catch { firstError = firstError ?? error }
        if let lowPower = original.batteryLowPowerMode {
            do { try exec(.setBatteryLowPowerMode(lowPower)) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
        markSwitchedOff()
        try originals.delete()
    }

    /// The state once the mode is off: the session's values are forgotten, and the saved state is kept only while fans are held.
    private func markSwitchedOff() {
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
        hotCore = .hotCore()
        hotBattery = .hotBattery()
        fanOverride = nil
        enabled = false
        owner = nil
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
    /// Without a saved state nothing was left behind, and the user's own settings stay as they are.
    public func recoverOnStart() throws {
        let saved: SavedState?
        let unreadable: Bool
        do {
            saved = try store.load()
            unreadable = false
        } catch {
            saved = nil
            unreadable = true
        }
        var firstError: Error?
        var fansStillHeld = false
        // A damaged file may hide a take-over, and handing back fans that macOS already has does no harm.
        if saved?.fansManual == true || unreadable || fansHeld, let hardware {
            do { try hardware.releaseFans() } catch { firstError = error; fansStillHeld = true }
        }
        if let lowPower = saved?.batteryLowPowerMode {
            do { try exec(.setBatteryLowPowerMode(lowPower)) } catch { firstError = firstError ?? error }
        }
        // A saved session (more than a fan take-over) holds the user's value. Without one the sleep setting is the
        // user's own already. A damaged file falls back to the old behaviour: sleep allowed.
        let session = saved.map { $0.sleepDisabled != nil || $0.batteryLowPowerMode != nil } ?? false
        if session || unreadable {
            do { try exec(.setSleepDisabled(saved?.sleepDisabled ?? false)) } catch { firstError = firstError ?? error }
        }
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
    /// The curve and the safety floor follow the hottest sensor of the known groups, or the average CPU
    /// temperature when no group can be read; a core at its limit, a hot battery or a Mac that macOS reports as hot
    /// runs the fans at full speed instead.
    /// Any fault (a failed read or write, a lost temperature, a fan that drops out of the reading or does not
    /// follow its target) hands the fans back to macOS; `FanHealth` says when to take them again.
    public func updateFans(now: SuspendingClock.Instant = .now) {
        guard !terminating else { return }
        guard enabled, let policy = fanPolicy, !policy.isOff else {
            hotCore = .hotCore()
            hotBattery = .hotBattery()
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
        let hotBatteryActive = hotBattery.update(hottest: reading.groupTemperatures[.battery], now: now)
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
        guard let temperature = reading.hottestTemperature ?? reading.cpuTemperature else {
            fault("Cannot read the temperature sensors.", now: now)
            return
        }
        // A CPU that stops reading would leave the curve on the cooler groups and the hot-core watch blind.
        if reading.cpuTemperature != nil {
            cpuSeen = true
        } else if cpuSeen {
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
        } else if hotBatteryActive {
            .hotBattery
        } else if let level = thermal?.thermalLevel(), level >= .serious {
            .system
        } else {
            nil
        }
        let percent = override == nil
            ? policy.speed(at: temperature, caseTemperature: reading.groupTemperatures[.airflow]) : 100
        let maxDrop = allowedDrop(now: now)
        let targets = reading.fans.enumerated().map { index, fan in
            let wanted = FanCurve.speed(percent: percent, fan: fan)
            let previous = fanTargets.flatMap { index < $0.count ? $0[index] : nil }
            let smoothed = FanCurve.smoothed(previous: previous, wanted: wanted, maxDrop: maxDrop)
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
            fanTargetsWritten = now
            fanOverride = override
            health.tickHeld(now: now)
        } catch {
            fault("Could not set the fan speed: \(error)", now: now)
        }
    }

    /// How far the targets may fall now: `fanStepDown` for each `fanStepInterval` since the last write, never
    /// more than one step. Calls close together, such as several new policies in a row, share the step.
    private func allowedDrop(now: SuspendingClock.Instant) -> Double {
        guard let written = fanTargetsWritten else { return fanStepDown }
        let elapsed = written.duration(to: now)
        guard elapsed > .zero else { return 0 }
        return fanStepDown * min(elapsed / fanStepInterval, 1)
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
            systemThermalLevel: thermal?.thermalLevel(),
            hottestTemperature: reading?.hottestTemperature,
            hottestGroup: reading?.hottestGroup,
            groupTemperatures: reading?.groupTemperatures ?? [:],
            handBackFailed: fansHeld && releaseProblem != nil
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

    /// The values from before ClamDown switched on, for Remove Helper. A clean switch-on (`replacing`) records them
    /// afresh: while the mode was off they were the user's own, so a change made since, or a record left by an earlier
    /// install, must not win. After a session that was never undone the record stays, because the current values may
    /// be ClamDown's. An unreadable record (a damaged file) is always replaced, so it can never stop the switch-on.
    private func recordOriginalSettings(sleepDisabled: Bool, batteryLowPowerMode: Bool?, replacing: Bool) throws {
        if !replacing, let existing = try? originals.load(), existing != nil { return }
        try originals.save(OriginalSettings(
            sleepDisabled: sleepDisabled,
            batteryLowPowerMode: batteryLowPowerMode,
            recordedAt: Date()
        ))
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
