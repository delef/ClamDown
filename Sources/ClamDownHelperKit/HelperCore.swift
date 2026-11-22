import Foundation
import ClamDownSensors
import ClamDownShared

public enum HelperError: Error, Equatable, CustomStringConvertible {
    case notEnabled
    /// `pmset -g` did not show a `SleepDisabled` value, so the user's setting cannot be restored later.
    case unreadableSleepSetting
    /// The fans could not be handed back to macOS, so the original settings are not put back yet.
    case fansStillHeld
    /// A take-over is on record but the SMC cannot be reached to hand the fans back.
    case fansUnreachable

    /// The text the app shows. No final period: the app adds its own.
    public var description: String {
        switch self {
        case .notEnabled: "The mode is not on"
        case .unreadableSleepSetting: "pmset did not report the sleep setting"
        case .fansStillHeld: "ClamDown could not hand the fans back to macOS"
        case .fansUnreachable: "ClamDown cannot reach the fans to hand them back to macOS"
        }
    }
}

/// The helper's whole job: switch `disablesleep` and the battery profile's Low Power Mode,
/// drive the fans while the mode is on (and, when the app asks, while it is off), remember what to put back,
/// and undo everything when asked.
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
    /// How far a fan's target may fall per `fanStepInterval`, in rpm (`FanDecision.fallStep`; tests set their own).
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
    /// What is on disk, so fan changes can be added to it. Nil while nothing is, or before the file was read.
    private var saved: SavedState?

    /// The app's fan wishes for this session. Nil until the app sends them; dropped on switch-off.
    /// While the mode is off the app may still send them: a fan-only session, kept alive by sending them again.
    private var fanPolicy: FanPolicy?
    /// The app connection that started a fan-only session, while one runs. Its closing ends the session.
    private var fanOwner: UUID?
    /// When the app last sent the fan-only session's policy. Without a new one within the watchdog timeout,
    /// the session ends and macOS gets the fans back.
    private var lastFanPolicy: SuspendingClock.Instant?
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
    /// Every rule that decides the fan speed, with its averages and watches; started afresh whenever the helper is
    /// not asked to drive the fans.
    private var decision = FanDecision()
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
        fanStepDown: Double = FanDecision.fallStep,
        fanStepInterval: Duration = FanDecision.fallInterval
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
        // A damaged file reads as the recovery reads it: sleep allowed.
        let pending: SavedState?
        do { pending = try store.load() } catch { pending = SavedState(sleepDisabled: false) }
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
        // The mode brings its own policy; a fan-only session's must not drive the mode's fans if that one never comes.
        endFanOnlySession()
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
            // A session left by a failed recovery stays on disk, so its values are still put back later; fans whose
            // hand-back failed earlier are still held, and the next start must know that too.
            var state = pending.map { SavedState(batteryLowPowerMode: $0.batteryLowPowerMode, sleepDisabled: $0.sleepDisabled) }
                ?? SavedState()
            state.fansManual = fansHeld ? true : nil
            writeSaved(state)
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
    /// A fan-only session ends with the connection that started it, and only with that one.
    public func connectionClosed(_ connection: UUID) throws {
        if enabled, let owner, owner != connection { return }
        if !enabled, let fanOwner, fanOwner != connection { return }
        endFanOnlySession()
        try disable()
    }

    /// launchd is stopping the helper. Nothing may take the fans again after this, whatever the switch-off does.
    public func shutdown() throws {
        terminating = true
        // The process exits after this whatever the switch-off does, so the fans go back first.
        releaseFansIfHeld()
        try disable()
    }

    /// Always tries every step. On any sleep or Low Power Mode failure the state is kept, so a retry can finish the job;
    /// the mode then stays on and keeps driving the fans. The fans go back to macOS once the switch-off has worked.
    /// Fans that cannot be handed back do not block the switch-off: `updateFans` keeps retrying,
    /// and the saved state makes the next helper start retry too.
    /// While the mode is off the sleep setting and Low Power Mode are the user's own and stay untouched; only a
    /// session left on disk by a failed recovery is put back, which makes this a retry of that recovery.
    public func disable() throws {
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
    /// A fan-only session ends here too: the helper is about to go.
    public func restoreOriginalSettings() throws {
        endFanOnlySession()
        guard let original = (try? originals.load()) ?? nil else {
            releaseFansIfHeld()
            try disable()
            try? originals.delete()
            return
        }
        // Every step is tried. If the fans stay with ClamDown, the record and the saved state stay too, so a retry hands them back.
        var firstError: Error?
        do { try exec(.setSleepDisabled(original.sleepDisabled ?? false)) } catch { firstError = error }
        if let lowPower = original.batteryLowPowerMode {
            do { try exec(.setBatteryLowPowerMode(lowPower)) } catch { firstError = firstError ?? error }
        }
        releaseFansIfHeld()
        if fansHeld { firstError = firstError ?? HelperError.fansStillHeld }
        if let firstError { throw firstError }
        markSwitchedOff()
        try originals.delete()
    }

    /// The state once the mode is off: the session's values are forgotten, and the saved state is kept only while fans are held.
    private func markSwitchedOff() {
        releaseFansIfHeld()
        // A stale file would only cause one needless restore on the next start.
        writeSaved(SavedState(fansManual: fansHeld ? true : nil))
        priorSleepDisabled = nil
        priorBatteryLowPower = nil
        fanPolicy = nil
        fanOwner = nil
        lastFanPolicy = nil
        health.restart()
        fanIdle = true
        decision = FanDecision()
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
    /// A fan-only session the app stopped sending its policy to ends here too; the next fan tick hands the fans back.
    public func checkWatchdog(now: SuspendingClock.Instant = .now) -> Bool {
        guard enabled else {
            if fanPolicy != nil, let last = lastFanPolicy, last.duration(to: now) > watchdogTimeout {
                endFanOnlySession()
            }
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
        if saved?.fansManual == true || unreadable || fansHeld {
            if let hardware {
                do { try hardware.releaseFans() } catch { firstError = error; fansStillHeld = true }
            } else if saved?.fansManual == true || fansHeld {
                // The record stays, so a later start that can open the SMC hands them back.
                firstError = HelperError.fansUnreachable
                fansStillHeld = true
            }
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
        if let firstError {
            // The file stays as it is, for a retry; memory follows it, so a fan take-over is added to it, not written over it.
            self.saved = saved
            throw firstError
        }
        try? store.clear()
        self.saved = nil
    }

    // MARK: - Fans

    /// Stores the app's fan wishes and applies them at once. A new policy starts afresh, even after fan control has
    /// stopped; the same policy again changes nothing, so the app can send it as often as it likes.
    /// While the mode is off this starts or keeps alive a fan-only session owned by `owner`: the fans follow the
    /// policy until the app stops sending it, its connection closes, or the mode switches on and off again.
    /// A policy with no points ends it.
    public func setFanPolicy(_ policy: FanPolicy, owner: UUID? = nil, now: SuspendingClock.Instant = .now) throws {
        let repaired = policy.repaired()
        if !enabled {
            guard !repaired.isOff else {
                endFanOnlySession()
                updateFans(now: now)
                return
            }
            fanOwner = owner
            lastFanPolicy = now
        }
        guard repaired != fanPolicy else { return }
        fanPolicy = repaired
        health.restart()
        updateFans(now: now)
    }

    /// Forgets a fan-only session. The fans go back to macOS on the next fan tick.
    private func endFanOnlySession() {
        guard !enabled else { return }
        fanPolicy = nil
        fanOwner = nil
        lastFanPolicy = nil
    }

    /// Call every few seconds. Sets the fan speeds while the mode is on or a fan-only session runs, and the policy
    /// asks for it;
    /// in every other case it hands the fans back to macOS if ClamDown holds them.
    /// The speed itself is `FanDecision`'s; this reads the sensors, applies it and handles faults.
    /// Any fault (a failed read or write, a lost temperature, a fan that drops out of the reading or does not
    /// follow its target) hands the fans back to macOS; `FanHealth` says when to take them again.
    public func updateFans(now: SuspendingClock.Instant = .now) {
        guard !terminating else { return }
        guard let policy = fanPolicy, !policy.isOff else {
            decision = FanDecision()
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
        // Kept up while the lid is open too, so closing it finds the averages and the watches already right.
        let observation = decision.observe(Self.sensors(reading), now: now)
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
        // A fan whose range is broken would get a target of its maximum, which can be 0 rpm or under its minimum.
        if let bad = reading.fans.firstIndex(where: { $0.maximum <= 0 || $0.maximum < $0.minimum }) {
            fault("Fan \(bad + 1) reports no usable speed range.", now: now)
            return
        }
        knownFanMaxima = reading.fans.map(\.maximum)
        // Without a temperature the curve cannot work, and guessing is worse than macOS's own control.
        guard let temperature = observation.temperature else {
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
        let override = FanDecision.override(observation, systemLevel: thermal?.thermalLevel())
        let percent = FanDecision.percent(policy: policy, temperature: temperature,
                                          airflow: reading.groupTemperatures[.airflow], override: override)
        let maxDrop = FanDecision.allowedDrop(after: fanTargetsWritten.map { $0.duration(to: now) },
                                              step: fanStepDown, interval: fanStepInterval)
        let targets = FanDecision.targets(percent: percent, fans: reading.fans, previous: fanTargets, maxDrop: maxDrop)
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

    /// The values `FanDecision` needs from a reading.
    private static func sensors(_ reading: HardwareReading) -> FanDecision.Sensors {
        FanDecision.Sensors(groups: reading.groupTemperatures, zones: reading.zoneTemperatures,
                            hottestCore: reading.hottestCPUTemperature, cpuAverage: reading.cpuTemperature)
    }

    /// What the helper sees and does right now. Reads the sensors but changes nothing.
    public func coolingStatus() -> CoolingStatus {
        let reading = try? hardware?.read()
        let followed = reading.map { decision.followed(Self.sensors($0)) }
        let hottest = followed.flatMap { SensorGroup.hottest(in: $0) }
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
            hottestTemperature: hottest?.celsius,
            hottestGroup: hottest?.group,
            groupTemperatures: followed ?? [:],
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
        try? recordFansHeld(false)
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

    /// Adds the take-over to what is on disk, or takes it off, and keeps everything else there: a session a failed
    /// recovery left behind must survive a fan-only session. Without a copy in memory the file is read first; a damaged
    /// one stands for "sleep allowed", as the recovery reads it.
    private func recordFansHeld(_ held: Bool) throws {
        var state: SavedState
        if let saved {
            state = saved
        } else {
            do { state = try store.load() ?? SavedState() } catch { state = SavedState(sleepDisabled: false) }
        }
        state.fansManual = held ? true : nil
        if state == SavedState() {
            try store.clear()
            saved = nil
        } else {
            try store.save(state)
            saved = state
        }
    }

    /// Writes `state`, or clears the file when it holds nothing. Best effort: used on paths that are already failing
    /// or finishing.
    private func writeSaved(_ state: SavedState) {
        if state == SavedState() {
            try? store.clear()
            saved = nil
        } else {
            try? store.save(state)
            saved = state
        }
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
