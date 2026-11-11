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

/// Owns the on/off switch: talks to the helper, applies the cut-off rules, keeps the user informed.
@MainActor
public final class ClamDownController: ObservableObject {
    @Published public private(set) var state: SwitchState = .off
    /// One line for the menu: why the switch is off, or what went wrong.
    @Published public private(set) var notice: String?
    @Published public private(set) var settings: Settings
    /// When the timer will switch the mode off. Nil while off or when no timer is running.
    @Published public private(set) var offAt: Date?

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
    private let now: @Sendable () -> Date
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
        now: @escaping @Sendable () -> Date = { Date() }
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
        self.now = now
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
        announce("Turned off: the helper stopped the mode.")
    }

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

    /// Temperatures and fans as the helper reads them. Nil when the helper cannot be reached.
    public func coolingStatus() async -> CoolingStatus? {
        try? await helper.coolingStatus()
    }

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
        if state.isOn {
            await turnOff()
            guard !state.isOn else { return }
        }
        notice = nil
        do {
            try reregisterHelper()
        } catch {
            state = .failed("Could not reinstall the helper: \(Self.describe(error))")
            return
        }
        installedHelper.fingerprint = nil
        guard reportReadiness(registrar.availability()) else { return }
        installedHelper.fingerprint = helperFingerprint
        notice = "Helper reinstalled."
    }

    /// Restores every setting to its default. Launch at login is the system's own state, so it stays as it is.
    public func resetSettings() async {
        var defaults = Settings()
        defaults.launchAtLogin = settings.launchAtLogin
        await updateSettings(defaults)
    }

    /// The helper's registration state, read from the system each time.
    public var helperAvailability: HelperAvailability { registrar.availability() }

    /// Removes the helper. Turn On sets it up again.
    public func removeHelper() async {
        if state.isOn {
            await turnOff()
            guard !state.isOn else { return }
        }
        do {
            try registrar.unregister()
        } catch {
            state = .failed("Could not remove the helper: \(Self.describe(error))")
            return
        }
        installedHelper.fingerprint = nil
        state = .off
        notice = "Helper removed. Turn On sets it up again."
    }

    // MARK: - Switching

    private func performTurnOn(duration: Duration?) async {
        notice = nil
        guard await helperIsReady() else { return }
        if let reason = AutoOffPolicy.reason(for: monitor.snapshot(), settings: settings) {
            let text = "Not turned on: \(reason.summary)."
            state = .off
            announce(text)
            return
        }
        do {
            try await helper.enable(lowPowerOnBattery: settings.autoLowPowerOnBattery)
        } catch {
            state = .failed(Self.describe(error))
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
            // Stop the heartbeat on purpose: the helper's own watchdog then resets the Mac within about 90 seconds.
            finishOff()
            announce("Turned off: \(reason.summary). The helper did not confirm, so it will reset by itself within 90 seconds.")
            return
        }
        finishOff()
        announce("Turned off: \(reason.summary). The Mac can sleep now.")
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

    /// Registers the helper when needed. Returns false and sets `state` when the user must act or it failed.
    private func helperIsReady() async -> Bool {
        var availability = registrar.availability()
        if availability.canAttemptRegistration {
            do {
                try registrar.register()
            } catch {
                let afterAttempt = registrar.availability()
                // Registering can throw when approval is pending; that is not a failure.
                // An unavailable helper keeps its own message below, which says more than the registration error.
                if afterAttempt != .requiresApproval, !afterAttempt.isUnavailable {
                    state = .failed(Self.describe(error))
                    return false
                }
            }
            availability = registrar.availability()
            recordInstalledBuild(after: availability)
        }
        guard reportReadiness(availability) else { return false }
        return syncHelperIfNeeded()
    }

    /// Sets `state` for every availability except ready. Returns true only when the helper is ready.
    private func reportReadiness(_ availability: HelperAvailability) -> Bool {
        switch availability {
        case .ready:
            return true
        case .requiresApproval:
            state = .needsApproval
            registrar.openApprovalSettings()
            return false
        case .notRegistered:
            state = .failed("The helper could not be registered.")
            return false
        case .unavailable(let message):
            state = .failed(message)
            return false
        }
    }

    /// Reinstalls the helper when the registered one comes from another build, so launchd runs this build's binary.
    /// Returns false, with `state` set, when that fails or the helper needs approval again.
    private func syncHelperIfNeeded() -> Bool {
        guard let fingerprint = helperFingerprint, installedHelper.fingerprint != fingerprint else { return true }
        do {
            try reregisterHelper()
        } catch {
            state = .failed("Could not update the helper: \(Self.describe(error))")
            return false
        }
        let availability = registrar.availability()
        recordInstalledBuild(after: availability)
        return reportReadiness(availability)
    }

    /// Records this build as the registered helper once registering it went through, even while approval is pending.
    /// Without the record, the next Turn On would reinstall the same build and could ask for approval again.
    private func recordInstalledBuild(after availability: HelperAvailability) {
        guard let helperFingerprint, availability == .ready || availability == .requiresApproval else { return }
        installedHelper.fingerprint = helperFingerprint
    }

    /// Unregisters and registers the helper again. Approval still pending after registering is not an error.
    private func reregisterHelper() throws {
        do {
            try registrar.unregister()
            try registrar.register()
        } catch {
            if registrar.availability() == .requiresApproval { return }
            throw error
        }
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

    private static func describe(_ error: Error) -> String {
        switch error as? HelperClientError {
        case .helper(let message), .connection(let message): message
        case .unsigned: "The app is not code-signed, so it cannot talk to the helper."
        case nil: String(describing: error)
        }
    }
}
