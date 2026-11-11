import Foundation

/// Holds a process activity so macOS does not throttle the heartbeat timer while the lid is closed.
public final class AppNapActivity: ProcessActivityHolding {
    private var token: NSObjectProtocol?

    public init() {}

    public func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "ClamDown is keeping the Mac awake")
    }

    public func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
