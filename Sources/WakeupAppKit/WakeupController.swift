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
public final class WakeupController: ObservableObject {
    @Published public private(set) var state: SwitchState = .off
    /// One line for the menu: why the switch is off, or what went wrong.
    @Published public private(set) var notice: String?
    @Published public private(set) var settings: Settings

    private let helper: HelperControlling
    private let registrar: HelperRegistering
    private let monitor: SystemMonitoring
    private let settingsStore: SettingsStoring
    private let notifier: Notifying
    private let activity: ProcessActivityHolding
    private let heartbeatInterval: Duration
    private var heartbeatTask: Task<Void, Never>?

    public init(
        helper: HelperControlling,
        registrar: HelperRegistering,
        monitor: SystemMonitoring,
        settingsStore: SettingsStoring,
        notifier: Notifying,
        activity: ProcessActivityHolding,
        heartbeatInterval: Duration = .seconds(30)
    ) {
        self.helper = helper
        self.registrar = registrar
        self.monitor = monitor
        self.settingsStore = settingsStore
        self.notifier = notifier
        self.activity = activity
        self.heartbeatInterval = heartbeatInterval
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
            await turnOn()
        }
    }

    /// Re-checks the cut-off rules after any power, battery, thermal or wake event.
    /// While on and still allowed to run, it also confirms with the helper that the mode is still on.
    public func handleSystemChange() async {
        guard state.isOn else { return }
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
        settings = new.clamped()
        settingsStore.save(settings)
        if state.isOn, settings.autoLowPowerOnBattery != previous.autoLowPowerOnBattery {
            do {
                try await helper.setLowPowerOnBattery(settings.autoLowPowerOnBattery)
            } catch {
                notice = "Could not change Low Power Mode: \(Self.describe(error))"
            }
        }
        await handleSystemChange()
    }

    /// Call when the app quits.
    public func shutdown() async {
        monitor.stop()
        if state.isOn { await turnOff() }
    }

    // MARK: - Switching

    private func turnOn() async {
        notice = nil
        guard await helperIsReady() else { return }
        if let reason = AutoOffPolicy.reason(for: monitor.snapshot(), settings: settings) {
            let text = "Not turned on: \(reason.summary)."
            state = .off
            notice = text
            notifier.post(title: "Wakeup", body: text)
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
        notifier.post(title: "Wakeup", body: text)
    }

    private func finishOff() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        activity.end()
        state = .off
    }

    /// Registers the helper when needed. Returns false and sets `state` when the user must act or it failed.
    private func helperIsReady() async -> Bool {
        var availability = registrar.availability()
        if availability == .notRegistered {
            do {
                try registrar.register()
            } catch {
                // Registering can throw when approval is pending; that is not a failure.
                if registrar.availability() != .requiresApproval {
                    state = .failed(Self.describe(error))
                    return false
                }
            }
            availability = registrar.availability()
        }
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

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.sendHeartbeat()
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
