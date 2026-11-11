import Foundation
import ClamDownShared

/// Accepts connections that already passed the listener's code-signing requirement
/// (set in the daemon's `main.swift`) and exports `HelperService` on them.
public final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let core: HelperCore

    public init(core: HelperCore) {
        self.core = core
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ClamDownHelperXPC.self)
        connection.exportedObject = HelperService(core: core)
        // The app is gone (quit, crash, kill): put everything back right away.
        let core = core
        let reset: @Sendable () -> Void = { Task { try? await core.disable() } }
        connection.invalidationHandler = reset
        connection.interruptionHandler = reset
        connection.resume()
        return true
    }
}
