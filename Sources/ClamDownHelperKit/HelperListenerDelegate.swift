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
        let service = HelperService(core: core)
        connection.exportedObject = service
        // The app is gone (quit, crash, kill): put everything back right away, unless it has switched on again
        // through a newer connection.
        let core = core
        let id = service.connection
        let reset: @Sendable () -> Void = { Task { try? await core.connectionClosed(id) } }
        connection.invalidationHandler = reset
        connection.interruptionHandler = reset
        connection.resume()
        return true
    }
}
