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
    public private(set) var settings: Settings

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

    public func toggle() async {
        if state.isOn {
            await turnOff()
        } else {
            await turnOn()
        }
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
                guard self != nil, !Task.isCancelled else { return }
                // Task 10 sends the heartbeat here.
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
