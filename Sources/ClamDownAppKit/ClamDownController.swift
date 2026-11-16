import ClamDownSensors
import ClamDownShared
import Combine
import Foundation
import os

/// What a Turn On did and when, for Console: `log stream --predicate 'subsystem == "app.clamdown"'`.
let turnOnLog = Logger(subsystem: "app.clamdown", category: "turn-on")

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

/// What a Turn On is doing while it runs. Getting the helper going can take half a minute, and after a click in
/// the menu the menu closes, so the icon and the reopened menu show that something is under way.
public enum TurnOnStep: Equatable, Sendable {
    case starting
    /// Registering the helper, or replacing one from another build.
    case settingUpHelper
    /// The helper is registered and macOS has not started it yet.
    case waitingForHelper
    /// launchd refused to start a helper registered moments ago. macOS usually asks for approval a few seconds
    /// later; registering it again would only start that wait over.
    case waitingForMacOS

    public var text: String {
        switch self {
        case .starting: String(localized: "Turning on…")
        case .settingUpHelper: String(localized: "Setting up the helper…")
        case .waitingForHelper: String(localized: "Waiting for the helper to start…")
        case .waitingForMacOS: String(localized: "macOS has not started the helper")
        }
    }

    /// One sentence under `text` where there is room for it.
    public var detail: String {
        switch self {
        case .waitingForMacOS: String(localized: "If macOS wants your permission, it asks in a few seconds.")
        default: String(localized: "This can take up to half a minute.")
        }
    }
}

/// Whether an allowed helper really runs. macOS can report it allowed while launchd never starts it.
public enum HelperRunCheck: Equatable, Sendable {
    case answers
    /// launchd says it could not start the helper.
    case startFailed
    /// No answer yet, and launchd says nothing that rules out a late start.
    case silent
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
    /// Set while a Turn On runs, nil otherwise.
    @Published public private(set) var turnOnStep: TurnOnStep?
    /// A second menu line while the helper has stopped controlling the fans. The mode itself still works.
    @Published public private(set) var fanControlLine: String?
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
    /// Asks launchd whether it could start the helper. Nil, or an unknown answer, leaves only the waiting.
    private let jobReader: HelperJobReading?
    /// True once this Turn On has registered the helper. launchd refusing a registration that new is macOS's
    /// decision, and registering again would not change it.
    private var registeredThisTurnOn = false
    /// Waits for the Mac to fall asleep after ClamDown asked for it, and asks again when it did not.
    private(set) var sleepWatch: Task<Void, Never>?
    /// What to tell the user when they open the lid after ClamDown let the Mac sleep.
    private var pendingWakeReport: WakeReport?
    /// True while a Turn On or a helper install, update or removal runs. These wait on macOS, so a second button
    /// press can arrive in the middle; it is turned away instead of racing the first.
    private var helperBusy = false
    /// Decides when the user hears that fan control has stopped.
    private var fanAlert = FanAlert()
    /// How long the battery has been hot. Starts again at every Turn On and every system sleep.
    private var batteryHeat = BatteryHeatWatch()

    private struct WakeReport {
        /// When ClamDown switched off.
        let at: Date
        /// Why, as a whole sentence in the past tense.
        let why: String
        /// True when the lid was closed at the switch-off: nobody saw the notification then.
        let away: Bool
        /// True once ClamDown asked for the sleep itself.
        var forced = false
        /// True once the Mac went to sleep after the switch-off. A switch-off that no sleep followed needs no second telling.
        var slept = false

        func text(asOf now: Date) -> String {
            let what: String
            if Calendar.current.isDate(at, inSameDayAs: now) {
                let time = at.formatted(date: .omitted, time: .shortened)
                what = forced ? String(localized: "ClamDown put the Mac to sleep at \(time).")
                    : String(localized: "ClamDown let the Mac sleep at \(time).")
            } else {
                let date = at.formatted(date: .abbreviated, time: .shortened)
                what = forced ? String(localized: "ClamDown put the Mac to sleep on \(date).")
                    : String(localized: "ClamDown let the Mac sleep on \(date).")
            }
            return String.sentences(what, why)
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
    /// Waits between heartbeats and until the timer ends. Tests replace it with time they move by hand.
    private let wait: @Sendable (Duration) async -> Void
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
        jobReader: HelperJobReading? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
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
        self.jobReader = jobReader
        self.now = now
        self.pause = pause
        self.wait = wait
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
        if let reason = autoOffReason() {
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
        if stillOn {
            await watchFanControl()
            return
        }
        guard state.isOn else { return }
        finishOff()
        // The helper also goes quiet when macOS stops it, for example after its approval is switched off in Login Items.
        refreshHelperAvailability()
        let helperStillAllowed = helperAvailability == .ready
        announce(helperStillAllowed ? String(localized: "Turned off because the helper stopped the mode.") : Self.helperLost)
        leaveWakeReport(why: helperStillAllowed
            ? String(localized: "The helper stopped the mode.")
            : String(localized: "macOS no longer allowed the helper."))
    }

    /// Call when the Mac is about to sleep.
    public func systemWillSleep() {
        stopSleepWatch()
        // Time asleep is not time hot: the hold starts again after the wake.
        batteryHeat.reset()
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

    static let helperLost = String(localized: "Turned off because macOS no longer allows the helper. Open Setup to allow it again.")

    public func updateSettings(_ new: Settings) async {
        let previous = settings
        let candidate = new.clamped()
        // Store first: memory must never differ from what is on disk, so a failed save changes nothing.
        do {
            try settingsStore.save(candidate)
        } catch {
            notice = String(localized: "Could not save settings: \(Self.describe(error))")
            return
        }
        settings = candidate
        if state.isOn, settings.autoLowPowerOnBattery != previous.autoLowPowerOnBattery {
            do {
                try await helper.setLowPowerOnBattery(settings.autoLowPowerOnBattery)
            } catch {
                notice = String(localized: "Could not change Low Power Mode: \(Self.describe(error))")
            }
        }
        if state.isOn, settings.fanPolicy != previous.fanPolicy {
            await applyFanPolicy()
        }
        if !settings.fanControlEnabled { present(fanAlert.reset()) }
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
            hottestCPUTemperature: reading.hottestCPUTemperature,
            fans: reading.fans,
            isControlling: false,
            problem: Self.noHelperForFans,
            hottestTemperature: reading.hottestTemperature,
            hottestGroup: reading.hottestGroup,
            groupTemperatures: reading.groupTemperatures
        )
    }

    /// The battery's temperature now, as the hot-battery rule sees it. Nil when the Mac does not say.
    public func batteryTemperature() -> Double? {
        monitor.snapshot().batteryTemperature
    }

    static let noHelperForFans = String(localized: "The helper is not running, so ClamDown cannot drive the fans yet. Turn ClamDown on once to set it up.")

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
            state = .failed(String(localized: "Could not reinstall the helper: \(Self.describe(error))"))
            return
        }
        installedHelper.fingerprint = nil
        refreshHelperAvailability()
        guard show(Self.preparation(for: helperAvailability)) else { return }
        installedHelper.fingerprint = helperFingerprint
        notice = String(localized: "Helper reinstalled.")
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

    /// Puts the original power settings back, then removes the helper. Turn On sets it up again.
    /// If the settings cannot be put back, the helper stays, because only it can still change them.
    public func removeHelper() async {
        guard !helperBusy else { return }
        helperBusy = true
        defer { helperBusy = false }
        if state.isOn {
            await turnOff()
            guard !state.isOn else { return }
        }
        // A helper that answers with a failure stays, so the user can try again. One that cannot be reached
        // (not approved, or an older build without this call) is removed anyway: the mode is off, so its own
        // switch-off already put sleep and Low Power Mode back, and it could never restore anything later.
        var unreached = false
        do {
            try await helper.restoreOriginalSettings()
        } catch HelperClientError.connection, HelperClientError.unsigned {
            unreached = true
        } catch {
            let reason = Self.describe(error).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            notice = String(localized: "Could not put the original power settings back: \(reason). The helper stays installed.")
            return
        }
        do {
            try await registrar.unregister()
        } catch {
            state = .failed(String(localized: "Could not remove the helper: \(Self.describe(error))"))
            return
        }
        installedHelper.fingerprint = nil
        state = .off
        notice = unreached
            ? String(localized: "Helper removed. It did not answer, so the original power settings were not checked. Turn On sets it up again.")
            : String(localized: "Helper removed. Turn On sets it up again.")
        refreshHelperAvailability()
    }

    // MARK: - Switching

    private func performTurnOn(duration: Duration?) async {
        guard !helperBusy else { return }
        helperBusy = true
        turnOnLog.info("turn on")
        turnOnStep = .starting
        registeredThisTurnOn = false
        defer {
            helperBusy = false
            turnOnStep = nil
            turnOnLog.info("turn on ended: \(String(describing: self.state), privacy: .public)")
        }
        notice = nil
        // The user is back and acting, so an undelivered "why the Mac slept" is old news.
        pendingWakeReport = nil
        stopSleepWatch()
        let preparation = await prepareHelperExclusively()
        pendingTurnOn = preparation == .needsApproval ? TurnOnRequest(duration: duration) : nil
        guard show(preparation) else { return }
        batteryHeat.reset()
        if let reason = autoOffReason() {
            let text = reason.notTurnedOnText
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
            notice = String(localized: "Could not control the fans: \(Self.describe(error))")
        }
    }

    private enum ModeStart {
        case started
        /// Not started; what the user is shown instead.
        case stopped(HelperPreparation)
    }

    /// A healthy helper answers at once, so two looks tell a slow start from a silent helper.
    static let helperQuickLooks = 2
    /// After a fresh registration macOS can take about ten seconds to say that it wants the helper allowed again.
    static let helperStartLooks = 8
    static let helperStartPause: Duration = .seconds(2)

    /// Asks the helper to switch the mode on, and deals with a helper that is registered and allowed but silent.
    ///
    /// Two things were seen on a real Mac. macOS can refuse to launch a helper it has just registered and only
    /// then, about ten seconds later, ask the user to allow it again. And after the user has allowed it, macOS
    /// can keep the old job, which can no longer start. In both the registration reads "allowed" and every
    /// request fails. So a silent helper is looked at again, registered afresh once, and looked at for longer:
    /// it may start late, or macOS may ask for approval, and then the user is led to that.
    private func startMode() async -> ModeStart {
        let start = ContinuousClock.now
        do {
            try await helper.enable(lowPowerOnBattery: settings.autoLowPowerOnBattery)
            return .started
        } catch {
            turnOnLog.info("first request: no answer after \(String(describing: ContinuousClock.now - start), privacy: .public)")
            // The helper answered with a failure of its own: waiting changes nothing.
            guard Self.isSilence(error) else { return .stopped(.failed(Self.describe(error))) }
        }
        advance(to: .waitingForHelper)
        // launchd may know already that the helper cannot start, and then the quick looks are skipped.
        let first: Look = await launchFailed() ? .launchFailed : await lookForHelper(Self.helperQuickLooks)
        switch first {
        case .settled(let outcome):
            return outcome
        case .launchFailed where registeredThisTurnOn:
            return await waitForMacOS()
        case .launchFailed, .silent:
            break
        }

        advance(to: .settingUpHelper)
        do {
            try await reregisterHelper()
            registeredThisTurnOn = true
        } catch {
            refreshHelperAvailability()
            return .stopped(.failed(String(localized: "The helper did not answer, and registering it again failed: \(Self.describe(error))")))
        }
        let availability = registrar.availability()
        helperAvailability = availability
        recordInstalledBuild(after: availability)
        guard availability == .ready else { return .stopped(Self.preparation(for: availability)) }
        advance(to: .waitingForHelper)
        do {
            try await helper.enable(lowPowerOnBattery: settings.autoLowPowerOnBattery)
            return .started
        } catch {
            guard Self.isSilence(error) else { return .stopped(.failed(Self.describe(error))) }
        }
        let second: Look = await launchFailed() ? .launchFailed : await lookForHelper(Self.helperStartLooks)
        switch second {
        case .settled(let outcome): return outcome
        case .launchFailed: return await waitForMacOS()
        case .silent: return .stopped(.failed(XPCHelperClient.noAnswer))
        }
    }

    private enum Look {
        /// The helper answered, or macOS changed its mind about allowing it.
        case settled(ModeStart)
        /// launchd says it could not start the helper.
        case launchFailed
        /// Still allowed, still silent, to the end.
        case silent
    }

    /// Looks at the helper every two seconds.
    private func lookForHelper(_ looks: Int) async -> Look {
        for _ in 0..<looks {
            await pause(Self.helperStartPause)
            if let outcome = await tryHelperOnce() { return .settled(outcome) }
            if await launchFailed() { return .launchFailed }
        }
        return .silent
    }

    /// launchd refused a helper registered in this Turn On. macOS asks for approval some seconds later, or the
    /// helper starts after all; if neither happens, the user is told so instead of being left waiting.
    private func waitForMacOS() async -> ModeStart {
        advance(to: .waitingForMacOS)
        for _ in 0..<Self.helperStartLooks {
            await pause(Self.helperStartPause)
            if let outcome = await tryHelperOnce() { return outcome }
        }
        refreshHelperAvailability()
        return .stopped(.failed(Self.macOSDidNotStartHelper))
    }

    static let macOSDidNotStartHelper = String(localized: """
        macOS did not start the helper. Choose Reinstall Helper in the menu, or check that ClamDown is allowed in \
        System Settings > General > Login Items & Extensions.
        """)

    /// One look: nil while the helper is still allowed and silent.
    private func tryHelperOnce() async -> ModeStart? {
        let availability = registrar.availability()
        guard availability == .ready else {
            turnOnLog.info("look: availability \(String(describing: availability), privacy: .public)")
            helperAvailability = availability
            return .stopped(Self.preparation(for: availability))
        }
        let start = ContinuousClock.now
        do {
            try await helper.enable(lowPowerOnBattery: settings.autoLowPowerOnBattery)
            turnOnLog.info("look: helper answered after \(String(describing: ContinuousClock.now - start), privacy: .public)")
            return .started
        } catch {
            turnOnLog.info("look: no answer after \(String(describing: ContinuousClock.now - start), privacy: .public)")
            guard Self.isSilence(error) else { return .stopped(.failed(Self.describe(error))) }
            return nil
        }
    }

    /// Asks the helper for its state. Any answer, even an error of its own, means it runs.
    public func checkHelperRuns() async -> HelperRunCheck {
        do {
            _ = try await helper.isEnabled()
            return .answers
        } catch {
            guard Self.isSilence(error) else { return .answers }
        }
        return await launchFailed() ? .startFailed : .silent
    }

    private func launchFailed() async -> Bool {
        guard let jobReader else { return false }
        let state = await jobReader.state()
        turnOnLog.info("launchd: \(String(describing: state), privacy: .public)")
        guard case .spawnFailed = state else { return false }
        return true
    }

    /// True when the request never reached a helper, as opposed to a helper that answered with a failure.
    private static func isSilence(_ error: Error) -> Bool {
        if case .connection? = error as? HelperClientError { return true }
        return false
    }

    /// The cut-off rules for the current snapshot. Also moves the hot-battery hold on, so call it once per check.
    private func autoOffReason() -> AutoOffReason? {
        let snapshot = monitor.snapshot()
        let heat = batteryHeat.update(snapshot, settings: settings, now: now())
        return AutoOffPolicy.reason(for: snapshot, settings: settings, batteryHeat: heat)
    }

    private func turnOff() async {
        do {
            try await helper.disable()
        } catch {
            // The helper may still be keeping the Mac awake, so the switch keeps showing "on".
            notice = String(localized: "Could not turn off: \(Self.describe(error))")
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
            let unconfirmed = String(localized: "The helper did not confirm, so it will reset by itself within 90 seconds.")
            announce(String.sentences(reason.turnedOffText, unconfirmed))
            leaveWakeReport(why: reason.pastText)
            return
        }
        guard state.isOn else { return }
        finishOff()
        let attendance = forcesSleep(after: reason) ? attendance() : .attended
        let outcome = attendance == .unattended
            ? String(localized: "The Mac is going to sleep.") : String(localized: "The Mac can sleep now.")
        announce(String.sentences(reason.turnedOffText, outcome))
        leaveWakeReport(why: reason.pastText)
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

    /// While the mode is on and fan control is switched on, asks the helper whether it still controls the fans,
    /// and says so once when it has stopped. Only the helper's answer counts: the app's own sensor reading
    /// says nothing about control.
    private func watchFanControl() async {
        guard state.isOn, settings.fanControlEnabled else {
            present(fanAlert.reset())
            return
        }
        let status = try? await helper.coolingStatus()
        // The mode or the switch may have changed while the helper answered.
        guard state.isOn, settings.fanControlEnabled else {
            present(fanAlert.reset())
            return
        }
        present(fanAlert.update(status))
    }

    private func present(_ change: FanAlert.Change) {
        switch change {
        case .none:
            break
        case .show(let line, let notify):
            fanControlLine = line
            if notify, settings.notificationsEnabled {
                notifier.post(title: String(localized: "ClamDown"), body: line)
            }
        case .clear:
            fanControlLine = nil
        }
    }

    private func announce(_ text: String) {
        notice = text
        if settings.notificationsEnabled {
            notifier.post(title: String(localized: "ClamDown"), body: text)
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
        timerTask = Task { [weak self, wait] in
            await wait(duration)
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
        // The helper hands the fans back at every switch-off, so a stop belongs to the session that ended.
        present(fanAlert.reset())
    }

    /// Registers the helper when needed and replaces one that comes from another build, without turning the mode on.
    /// It changes neither `state` nor System Settings: the caller decides what to show.
    public func prepareHelper() async -> HelperPreparation {
        guard !helperBusy else { return .failed(Self.helperBusyMessage) }
        helperBusy = true
        defer { helperBusy = false }
        return await prepareHelperExclusively()
    }

    static let helperBusyMessage = String(localized: "ClamDown is still setting up the helper. Try again in a moment.")

    /// The work of `prepareHelper()`. The caller holds `helperBusy`.
    private func prepareHelperExclusively() async -> HelperPreparation {
        var availability = registrar.availability()
        if availability.canAttemptRegistration {
            advance(to: .settingUpHelper)
            do {
                try registrar.register()
                registeredThisTurnOn = true
                turnOnLog.info("registered")
            } catch {
                let afterAttempt = registrar.availability()
                turnOnLog.info("registration refused: \((error as NSError).code, privacy: .public), availability \(String(describing: afterAttempt), privacy: .public)")
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
        case .notRegistered: .failed(String(localized: "The helper could not be registered."))
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
        advance(to: .settingUpHelper)
        do {
            try await reregisterHelper()
            registeredThisTurnOn = true
        } catch {
            refreshHelperAvailability()
            return .failed(String(localized: "Could not update the helper: \(Self.describe(error))"))
        }
        let availability = registrar.availability()
        helperAvailability = availability
        recordInstalledBuild(after: availability)
        return Self.preparation(for: availability)
    }

    /// Moves a running Turn On to its next step. Preparing the helper for the setup assistant is not a Turn On.
    private func advance(to step: TurnOnStep) {
        guard turnOnStep != nil else { return }
        turnOnLog.info("step \(String(describing: step), privacy: .public)")
        turnOnStep = step
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
                turnOnLog.info("registered again after \(String(describing: quietTime), privacy: .public)")
                return
            } catch {
                turnOnLog.info("registration refused: \((error as NSError).code, privacy: .public)")
                if registrar.availability() == .requiresApproval { return }
                refusal = error
            }
        }
        if let refusal { throw refusal }
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self, wait] in
            while !Task.isCancelled {
                await wait(interval)
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
        case .unsigned: return String(localized: "The app is not code-signed, so it cannot talk to the helper.")
        case nil: break
        }
        let systemError = error as NSError
        guard systemError.domain == "SMAppServiceErrorDomain" else { return systemError.localizedDescription }
        // Code 1 is "operation not permitted": macOS has not allowed the helper, or refused to start it.
        if systemError.code == 1 {
            return String(localized: "macOS did not allow the helper to start. Allow ClamDown in Login Items, then try again.")
        }
        return String(localized: "macOS could not set up the helper (error \(systemError.code)).")
    }
}
