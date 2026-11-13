import ClamDownSensors
import ClamDownShared
import Combine
import Foundation

public enum SwitchState: Equatable {
    case off
    case on
    /// The helper is registered but the user has not approved it yet.
    case needsApproval
    case failed(String)

    public var isOn: Bool { self == .on }
}

/// The outcome of getting the helper registered and up to date.
public enum HelperPreparation: Equatable, Sendable {
    case ready
    /// The helper is registered and waits for the user's approval in Login Items.
    case needsApproval
    case failed(String)
}

/// A Turn On that stopped because the helper needs approval. A nil duration means "until switched off".
public struct TurnOnRequest: Equatable, Sendable {
    public let duration: Duration?

    public init(duration: Duration?) {
        self.duration = duration
    }
}

/// Owns the on/off switch: talks to the helper, applies the cut-off rules, keeps the user informed.
@MainActor
public final class ClamDownController: ObservableObject {
    @Published public private(set) var state: SwitchState = .off
    /// One line for the menu: why the switch is off, or what went wrong.
    @Published public private(set) var notice: String?
    @Published public private(set) var settings: Settings
    /// When the timer will switch the mode off. Nil while off or when no timer is running.
    @Published public private(set) var offAt: Date?
    /// The helper's registration state as last read from the system. The icons follow it, so it is published;
    /// `refreshHelperAvailability()` reads it again.
    @Published public private(set) var helperAvailability: HelperAvailability = .ready
    /// The last Turn On that stopped for approval, so the setup assistant's "Turn On Now" can finish it.
    public private(set) var pendingTurnOn: TurnOnRequest?
    /// Called on every Turn On or reinstall that stops because the helper needs approval.
    /// The app answers by opening the setup assistant; System Settings no longer opens by itself.
    public var onHelperNeedsApproval: (@MainActor () -> Void)?
    /// Called with one sentence when the user opens the lid after ClamDown let the Mac sleep.
    public var onWakeReport: (@MainActor (String) -> Void)?

    private let helper: HelperControlling
    private let registrar: HelperRegistering
    private let monitor: SystemMonitoring
    private let settingsStore: SettingsStoring
    private let notifier: Notifying
    private let activity: ProcessActivityHolding
    private let installedHelper: InstalledHelperStoring
    /// Identifies the helper binary shipped in this build. Nil disables the automatic update.
    private let helperFingerprint: String?
    private let heartbeatInterval: Duration
    private let lidMonitor: LidMonitoring?
    private let screenLocker: ScreenLocking?
    /// Reads temperatures and fans directly when the helper cannot answer, for example before it is installed.
    private let sensors: SensorReading?
    private let lid: LidReading?
    private let idle: IdleReading?
    private let displays: DisplayReading?
    private let sleeper: SystemSleeping?
    /// Waits for the Mac to fall asleep after ClamDown asked for it, and asks again when it did not.
    private(set) var sleepWatch: Task<Void, Never>?
    /// What to tell the user when they open the lid after ClamDown let the Mac sleep.
    private var pendingWakeReport: WakeReport?
    /// True while a Turn On or a helper install, update or removal runs. These wait on macOS, so a second button
    /// press can arrive in the middle; it is turned away instead of racing the first.
    private var helperBusy = false

    private struct WakeReport {
        /// When ClamDown switched off.
        let at: Date
        let why: String
        /// True when the lid was closed at the switch-off: nobody saw the notification then.
        let away: Bool
        /// True once ClamDown asked for the sleep itself.
        var forced = false
        /// True once the Mac went to sleep after the switch-off. A switch-off that no sleep followed needs no second telling.
        var slept = false

        func text(asOf now: Date) -> String {
            let action = forced ? "put the Mac to sleep" : "let the Mac sleep"
            let when = Calendar.current.isDate(at, inSameDayAs: now)
                ? "at \(at.formatted(date: .omitted, time: .shortened))"
                : "on \(at.formatted(date: .abbreviated, time: .shortened))"
            return "ClamDown \(action) \(when): \(why)."
        }
    }

    /// How long after a switch-off a sleep still counts as its consequence, for a user who was at the Mac.
    static let reportWindow: TimeInterval = 30 * 60
    /// How long to wait for the Mac to fall asleep before asking again.
    static let sleepConfirmation: Duration = .seconds(20)
    static let sleepRequestLimit = 3
    /// Rounds of waiting and looking again, so a Mac that is never quiet is not watched for ever.
    static let sleepWatchRounds = 6
    private var sleepRequests = 0
    private let now: @Sendable () -> Date
    /// Waits for the given time. Tests replace it, so they do not wait for real.
    private let pause: @Sendable (Duration) async -> Void
    private var heartbeatTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    public init(
        helper: HelperControlling,
        registrar: HelperRegistering,
        monitor: SystemMonitoring,
        settingsStore: SettingsStoring,
        notifier: Notifying,
        activity: ProcessActivityHolding,
        installedHelper: InstalledHelperStoring,
        helperFingerprint: String? = nil,
        heartbeatInterval: Duration = .seconds(30),
        lidMonitor: LidMonitoring? = nil,
        screenLocker: ScreenLocking? = nil,
        sensors: SensorReading? = nil,
        lid: LidReading? = nil,
        idle: IdleReading? = nil,
        displays: DisplayReading? = nil,
        sleeper: SystemSleeping? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.helper = helper
        self.registrar = registrar
        self.monitor = monitor
        self.settingsStore = settingsStore
        self.notifier = notifier
        self.activity = activity
        self.installedHelper = installedHelper
        self.helperFingerprint = helperFingerprint
        self.heartbeatInterval = heartbeatInterval
        self.lidMonitor = lidMonitor
        self.screenLocker = screenLocker
        self.sensors = sensors
        self.lid = lid
        self.idle = idle
        self.displays = displays
        self.sleeper = sleeper
        self.now = now
        self.pause = pause
        self.settings = settingsStore.load()
    }

    /// Call once at launch: starts watching the system and cleans up after a killed or hung previous run.
    public func start() async {
        monitor.start { [weak self] in
            Task { @MainActor in await self?.handleSystemChange() }
        }
        if !state.isOn, let leftover = try? await helper.isEnabled(), leftover {
            try? await helper.disable()
        }
    }

    public func toggle() async {
        if state.isOn {
            await turnOff()
        } else {
            await performTurnOn(duration: settings.autoOffTimer.duration)
        }
    }

    /// Turns the mode on for a set time, whatever the timer setting says. Nil keeps it on until something else ends it.
    /// Does nothing while the mode is already on.
    public func turnOn(for duration: Duration?) async {
        guard !state.isOn else { return }
        await performTurnOn(duration: duration)
    }

    /// "Turn On Now" in the setup assistant: finishes the Turn On that waited for approval, with the duration
    /// it asked for. With none remembered it behaves like the menu's Turn On.
    public func resumeTurnOn() async {
        guard !state.isOn else {
            pendingTurnOn = nil
            return
        }
        // A remembered request with a nil duration means "until switched off", so it must not fall through to the setting.
        let duration = pendingTurnOn.map(\.duration) ?? settings.autoOffTimer.duration
        await performTurnOn(duration: duration)
    }

    /// Forgets the Turn On that waited for approval. Call when the setup assistant closes.
    public func dropPendingTurnOn() {
        pendingTurnOn = nil
    }

    /// Re-checks the cut-off rules after any power, battery, thermal or wake event.
    /// While on and still allowed to run, it also confirms with the helper that the mode is still on.
    public func handleSystemChange() async {
        guard state.isOn else { return }
        // A sleeping Mac cannot run the timer task, so the deadline is also checked on every wake and heartbeat.
        if let offAt, now() >= offAt {
            await autoOff(.timerEnded)
            return
        }
        if let reason = AutoOffPolicy.reason(for: monitor.snapshot(), settings: settings) {
            await autoOff(reason)
            return
        }
        await sendHeartbeat()
    }

    /// Tells the helper the app is alive. If the helper says the mode is off, or cannot be reached, so is the switch.
    public func sendHeartbeat() async {
        guard state.isOn else { return }
        let stillOn: Bool
        do {
            stillOn = try await helper.heartbeat()
        } catch {
            stillOn = false
        }
        guard !stillOn, state.isOn else { return }
        finishOff()
        // The helper also goes quiet when macOS stops it, for example after its approval is switched off in Login Items.
        refreshHelperAvailability()
        let helperStillAllowed = helperAvailability == .ready
        announce(helperStillAllowed ? "Turned off: the helper stopped the mode." : Self.helperLost)
        leaveWakeReport(why: helperStillAllowed ? "the helper stopped the mode" : "macOS no longer allows the helper")
    }

    /// Call when the Mac is about to sleep.
    public func systemWillSleep() {
        stopSleepWatch()
        guard var report = pendingWakeReport, !report.slept else { return }
        // A user who was at the Mac saw the switch-off when it happened. A sleep long after that is their own doing.
        guard report.away || now().timeIntervalSince(report.at) <= Self.reportWindow else {
            pendingWakeReport = nil
            return
        }
        report.slept = true
        pendingWakeReport = report
    }

    /// Call when the Mac or its screens wake. Tells the user why ClamDown let the Mac sleep, once, when the lid is open.
    public func systemDidWake() {
        guard let report = pendingWakeReport, report.slept else { return }
        // A power event can wake a Mac that is still closed in a bag. Keep the report for the person who opens it.
        if lid?.lid()?.closed == true { return }
        pendingWakeReport = nil
        let text = report.text(asOf: now())
        // "The Mac is going to sleep." is old news to the person reading the menu now.
        notice = text
        onWakeReport?(text)
    }

    static let helperLost = "Turned off: macOS no longer allows the helper. Open Setup to allow it again."

    public func updateSettings(_ new: Settings) async {
        let previous = settings
        let candidate = new.clamped()
        // Store first: memory must never differ from what is on disk, so a failed save changes nothing.
        do {
            try settingsStore.save(candidate)
        } catch {
            notice = "Could not save settings: \(Self.describe(error))"
            return
        }
        settings = candidate
        if state.isOn, settings.autoLowPowerOnBattery != previous.autoLowPowerOnBattery {
            do {
                try await helper.setLowPowerOnBattery(settings.autoLowPowerOnBattery)
            } catch {
                notice = "Could not change Low Power Mode: \(Self.describe(error))"
            }
        }
        if state.isOn, settings.fanPolicy != previous.fanPolicy {
            await applyFanPolicy()
        }
        await handleSystemChange()
    }

    /// Temperatures and fans as the helper reads them. Without the helper, the app reads them itself
    /// and says that the fans cannot be driven yet. Nil when neither can read them.
    public func coolingStatus() async -> CoolingStatus? {
        if let status = try? await helper.coolingStatus() { return status }
        guard let sensors else { return nil }
        let reading = await Task.detached { try? sensors.read() }.value
        guard let reading else { return nil }
        return CoolingStatus(
            cpuTemperature: reading.cpuTemperature,
            fans: reading.fans,
            isControlling: false,
            problem: Self.noHelperForFans
        )
    }

    static let noHelperForFans = "The helper is not running, so ClamDown cannot drive the fans yet. Turn ClamDown on once to set it up."

    /// Call when the app quits.
    public func shutdown() async {
        monitor.stop()
        if state.isOn { await turnOff() }
    }

    /// Opens the Login Items page, where the user approves the helper.
    public func openHelperApproval() {
        registrar.openApprovalSettings()
    }

    /// Installs the helper from this app build again. Use it when the helper gets stuck.
    public func reinstallHelper() async {
        guard !helperBusy else { return }
        helperBusy = true
        defer { helperBusy = false }
        if state.isOn {
            await turnOff()
            guard !state.isOn else { return }
        }
        notice = nil
        do {
            try await reregisterHelper()
        } catch {
            state = .failed("Could not reinstall the helper: \(Self.describe(error))")
            return
        }
        installedHelper.fingerprint = nil
        refreshHelperAvailability()
        guard show(Self.preparation(for: helperAvailability)) else { return }
        installedHelper.fingerprint = helperFingerprint
        notice = "Helper reinstalled."
    }

    /// Restores every setting to its default. Launch at login is the system's own state, so it stays as it is.
    public func resetSettings() async {
        var defaults = Settings()
        defaults.launchAtLogin = settings.launchAtLogin
        await updateSettings(defaults)
    }

    /// Reads the helper's registration state from the system again. macOS sends no notice when the user
    /// changes it in System Settings, so the app calls this on a timer.
    public func refreshHelperAvailability() {
        let current = registrar.availability()
        if current != helperAvailability { helperAvailability = current }
        // The user approved the helper without pressing Turn On again: nothing is waiting on them any more.
        if current == .ready, state == .needsApproval { state = .off }
    }

    /// True when ClamDown cannot work until the user does something: the helper is not ready, or switching on failed.
    /// An automatic switch-off is not such a case; the off icon and the menu's reason line cover it.
    public var needsAttention: Bool {
        if helperAvailability != .ready { return true }
        switch state {
        case .failed, .needsApproval: return true
        case .on, .off: return false
        }
    }

    /// Replaces the stored Launch at Login value with the system's, which the user can change in System Settings.
    public func syncLaunchAtLogin(systemValue: Bool) async {
        guard settings.launchAtLogin != systemValue else { return }
        var updated = settings
        updated.launchAtLogin = systemValue
        await updateSettings(updated)
    }

    /// Removes the helper. Turn On sets it up again.
    public func removeHelper() async {
        guard !helperBusy else { return }
        helperBusy = true
        defer { helperBusy = false }
        if state.isOn {
            await turnOff()
            guard !state.isOn else { return }
        }
        do {
            try await registrar.unregister()
        } catch {
            state = .failed("Could not remove the helper: \(Self.describe(error))")
            return
        }
        installedHelper.fingerprint = nil
        state = .off
        notice = "Helper removed. Turn On sets it up again."
        refreshHelperAvailability()
    }

    // MARK: - Switching

    private func performTurnOn(duration: Duration?) async {
        guard !helperBusy else { return }
        helperBusy = true
        defer { helperBusy = false }
        notice = nil
        // The user is back and acting, so an undelivered "why the Mac slept" is old news.
        pendingWakeReport = nil
        stopSleepWatch()
        let preparation = await prepareHelperExclusively()
        pendingTurnOn = preparation == .needsApproval ? TurnOnRequest(duration: duration) : nil
        guard show(preparation) else { return }
        if let reason = AutoOffPolicy.reason(for: monitor.snapshot(), settings: settings) {
            let text = "Not turned on: \(reason.summary)."
            state = .off
            announce(text)
            return
        }
        switch await startMode() {
        case .started:
            break
        case .stopped(let preparation):
            // The Turn On that found the helper not allowed is remembered, as when it is found before the start.
            pendingTurnOn = preparation == .needsApproval ? TurnOnRequest(duration: duration) : nil
            _ = show(preparation)
            return
        }
        activity.begin()
        state = .on
        startHeartbeatLoop()
        startAutoOffTimer(duration)
        lidMonitor?.start { [weak self] in
            Task { @MainActor in self?.lidDidClose() }
        }
        await applyFanPolicy()
    }

    /// The helper drops the fan policy on every switch-off, so it is sent on every switch-on and setting change.
    /// A failure leaves the fans with macOS and the mode on: keeping the Mac awake matters more.
    private func applyFanPolicy() async {
        do {
            try await helper.setFanPolicy(settings.fanPolicy)
        } catch {
            notice = "Could not control the fans: \(Self.describe(error))"
        }
    }

    private enum ModeStart {
        case started
        /// Not started; what the user is shown instead.
        case stopped(HelperPreparation)
    }

    /// How long a registered helper that does not answer is waited for: eight looks, two seconds apart.
    static let helperStartLooks = 8
    static let helperStartPause: Duration = .seconds(2)

    /// Asks the helper to switch the mode on, and waits for a helper that macOS has registered but not started.
    ///
    /// macOS can refuse to launch a helper it has just registered and only then, about ten seconds later, ask the
    /// user to allow it again. Until it does, the registration still reads "allowed" and every request fails.
    /// So a helper that does not answer is looked at again for a while: it may start late, or macOS may ask
    /// for approval, and then the user is led to that instead of being left with "the helper did not answer".
    private func startMode() async -> ModeStart {
        var failure: Error
        do {
            try await helper.enable(lowPowerOnBattery: settings.autoLowPowerOnBattery)
            return .started
        } catch {
            failure = error
        }
        // The helper answered with a failure of its own: waiting changes nothing.
        guard case .connection? = failure as? HelperClientError else { return .stopped(.failed(Self.describe(failure))) }

        notice = "Waiting for the helper to start…"
        defer { notice = nil }
        for _ in 0..<Self.helperStartLooks {
            await pause(Self.helperStartPause)
            let availability = registrar.availability()
            guard availability == .ready else {
                helperAvailability = availability
                return .stopped(Self.preparation(for: availability))
            }
            do {
                try await helper.enable(lowPowerOnBattery: settings.autoLowPowerOnBattery)
                return .started
            } catch {
                failure = error
            }
        }
        return .stopped(.failed(Self.describe(failure)))
    }

    private func turnOff() async {
        do {
            try await helper.disable()
        } catch {
            // The helper may still be keeping the Mac awake, so the switch keeps showing "on".
            notice = "Could not turn off: \(Self.describe(error))"
            return
        }
        finishOff()
    }

    private func autoOff(_ reason: AutoOffReason) async {
        do {
            try await helper.disable()
        } catch {
            // Another switch-off may have finished while this one waited for the helper.
            guard state.isOn else { return }
            // Stop the heartbeat on purpose: the helper's own watchdog then resets the Mac within about 90 seconds.
            finishOff()
            announce("Turned off: \(reason.summary). The helper did not confirm, so it will reset by itself within 90 seconds.")
            leaveWakeReport(why: reason.summary)
            return
        }
        guard state.isOn else { return }
        finishOff()
        let attendance = forcesSleep(after: reason) ? attendance() : .attended
        announce("Turned off: \(reason.summary). "
            + (attendance == .unattended ? "The Mac is going to sleep." : "The Mac can sleep now."))
        leaveWakeReport(why: reason.summary)
        startSleepWatch(attendance)
    }

    /// Protection fired: when nobody is at the Mac it is put to sleep, because an app can keep an idle Mac awake
    /// in a bag for as long as it likes.
    private func forcesSleep(after reason: AutoOffReason) -> Bool {
        reason.isProtective && settings.sleepAfterProtection && sleeper != nil
    }

    /// Whether somebody is at the Mac. The lid alone does not say: macOS refreshes "closing the lid sleeps this Mac"
    /// only on some events, so the keyboard and the displays have their say too.
    private func attendance() -> Attendance {
        Attendance(lid: lid?.lid(), idle: idle?.idleTime(), externalDisplay: displays?.hasExternalDisplay() ?? true)
    }

    /// Puts an unattended Mac to sleep, or waits for a Mac that was touched a moment ago to become quiet.
    private func startSleepWatch(_ attendance: Attendance) {
        stopSleepWatch()
        sleepRequests = 0
        let firstWait: Duration
        switch attendance {
        case .attended:
            return
        case .leaving(let untilQuiet):
            firstWait = untilQuiet
        case .unattended:
            requestSleep()
            firstWait = Self.sleepConfirmation
        }
        sleepWatch = Task { [weak self] in await self?.watchSleep(after: firstWait) }
    }

    private func stopSleepWatch() {
        sleepWatch?.cancel()
        sleepWatch = nil
    }

    private func requestSleep() {
        sleepRequests += 1
        pendingWakeReport?.forced = true
        sleeper?.sleepNow()
    }

    /// One request for sleep can be refused, so this asks again while the Mac stays awake and nobody is there.
    /// `systemWillSleep` ends it, and so does anyone coming back.
    private func watchSleep(after firstWait: Duration) async {
        var wait = firstWait
        for _ in 0..<Self.sleepWatchRounds {
            await pause(wait)
            guard !Task.isCancelled, !state.isOn, sleepRequests < Self.sleepRequestLimit else { return }
            switch attendance() {
            case .attended:
                return
            case .leaving(let untilQuiet):
                wait = untilQuiet
            case .unattended:
                requestSleep()
                wait = Self.sleepConfirmation
            }
        }
    }

    private func leaveWakeReport(why: String) {
        pendingWakeReport = WakeReport(at: now(), why: why, away: lid?.lid()?.closed == true)
    }

    private func announce(_ text: String) {
        notice = text
        if settings.notificationsEnabled {
            notifier.post(title: "ClamDown", body: text)
        }
    }

    private func startAutoOffTimer(_ duration: Duration?) {
        timerTask?.cancel()
        timerTask = nil
        guard let duration else {
            offAt = nil
            return
        }
        offAt = now().addingTimeInterval(TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18)
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() async {
        guard state.isOn else { return }
        await autoOff(.timerEnded)
    }

    /// With the lid closed and the Mac awake, nobody is watching it, so lock it before it travels or sits unattended.
    private func lidDidClose() {
        guard state.isOn, settings.lockScreenWhenLidClosed else { return }
        screenLocker?.lock()
    }

    private func finishOff() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        timerTask?.cancel()
        timerTask = nil
        offAt = nil
        lidMonitor?.stop()
        activity.end()
        state = .off
    }

    /// Registers the helper when needed and replaces one that comes from another build, without turning the mode on.
    /// It changes neither `state` nor System Settings: the caller decides what to show.
    public func prepareHelper() async -> HelperPreparation {
        guard !helperBusy else { return .failed(Self.helperBusyMessage) }
        helperBusy = true
        defer { helperBusy = false }
        return await prepareHelperExclusively()
    }

    static let helperBusyMessage = "ClamDown is still setting up the helper. Try again in a moment."

    /// The work of `prepareHelper()`. The caller holds `helperBusy`.
    private func prepareHelperExclusively() async -> HelperPreparation {
        var availability = registrar.availability()
        if availability.canAttemptRegistration {
            do {
                try registrar.register()
            } catch {
                let afterAttempt = registrar.availability()
                // Registering can throw when approval is pending; that is not a failure.
                // An unavailable helper keeps its own message below, which says more than the registration error.
                if afterAttempt != .requiresApproval, !afterAttempt.isUnavailable {
                    helperAvailability = afterAttempt
                    return .failed(Self.describe(error))
                }
            }
            availability = registrar.availability()
            recordInstalledBuild(after: availability)
        }
        helperAvailability = availability
        let preparation = Self.preparation(for: availability)
        guard preparation == .ready else { return preparation }
        return await syncHelperIfNeeded()
    }

    private static func preparation(for availability: HelperAvailability) -> HelperPreparation {
        switch availability {
        case .ready: .ready
        case .requiresApproval: .needsApproval
        case .notRegistered: .failed("The helper could not be registered.")
        case .unavailable(let message): .failed(message)
        }
    }

    /// Puts a preparation that did not end ready into `state`. Returns true only for ready.
    private func show(_ preparation: HelperPreparation) -> Bool {
        switch preparation {
        case .ready:
            return true
        case .needsApproval:
            state = .needsApproval
            onHelperNeedsApproval?()
            return false
        case .failed(let message):
            state = .failed(message)
            return false
        }
    }

    /// Reinstalls the helper when the registered one comes from another build, so launchd runs this build's binary.
    private func syncHelperIfNeeded() async -> HelperPreparation {
        guard let fingerprint = helperFingerprint, installedHelper.fingerprint != fingerprint else { return .ready }
        do {
            try await reregisterHelper()
        } catch {
            refreshHelperAvailability()
            return .failed("Could not update the helper: \(Self.describe(error))")
        }
        let availability = registrar.availability()
        helperAvailability = availability
        recordInstalledBuild(after: availability)
        return Self.preparation(for: availability)
    }

    /// Records this build as the registered helper once registering it went through, even while approval is pending.
    /// Without the record, the next Turn On would reinstall the same build and could ask for approval again.
    private func recordInstalledBuild(after availability: HelperAvailability) {
        guard let helperFingerprint, availability == .ready || availability == .requiresApproval else { return }
        installedHelper.fingerprint = helperFingerprint
    }

    /// How long to stay quiet before each attempt to register a helper that was just removed.
    ///
    /// macOS refuses a registration that follows a removal too closely, although the removal has finished:
    /// it wants a moment in which nobody asks it to register anything. Measured on macOS 27, 0.3 seconds is
    /// too short and 0.7 is enough, and a refused attempt starts the wait again. So the pauses grow.
    static let registrationPauses: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    /// Unregisters and registers the helper again. Approval still pending after registering is not an error.
    private func reregisterHelper() async throws {
        do {
            try await registrar.unregister()
        } catch {
            if registrar.availability() == .requiresApproval { return }
            throw error
        }
        var refusal: Error?
        for quietTime in Self.registrationPauses {
            await pause(quietTime)
            do {
                try registrar.register()
                return
            } catch {
                if registrar.availability() == .requiresApproval { return }
                refusal = error
            }
        }
        if let refusal { throw refusal }
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                // Also re-checks the cut-offs, so a missed system notification cannot disable the safety net.
                await self?.handleSystemChange()
            }
        }
    }

    /// One plain sentence for the user. Raw system errors read like "Error Domain=SMAppServiceErrorDomain Code=1".
    private static func describe(_ error: Error) -> String {
        switch error as? HelperClientError {
        case .helper(let message), .connection(let message): return message
        case .unsigned: return "The app is not code-signed, so it cannot talk to the helper."
        case nil: break
        }
        let systemError = error as NSError
        guard systemError.domain == "SMAppServiceErrorDomain" else { return systemError.localizedDescription }
        // Code 1 is "operation not permitted": macOS has not allowed the helper, or refused to start it.
        if systemError.code == 1 {
            return "macOS did not allow the helper to start. Allow ClamDown in Login Items, then try again."
        }
        return "macOS could not set up the helper (error \(systemError.code))."
    }
}
