import Foundation

/// Holds a process activity so macOS does not throttle the heartbeat timer while the lid is closed.
public final class AppNapActivity: ProcessActivityHolding {
    private var token: NSObjectProtocol?
    private let options: ProcessInfo.ActivityOptions
    private let reason: String

    public init(options: ProcessInfo.ActivityOptions = .userInitiated, reason: String = "ClamDown is keeping the Mac awake") {
        self.options = options
        self.reason = reason
    }

    /// For Always: keeps the fan session's timer on time without keeping the Mac awake.
    public static func cooling() -> AppNapActivity {
        AppNapActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "ClamDown is driving the fans")
    }

    public func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    }

    public func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
