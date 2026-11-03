import Foundation
import WakeupShared

/// Resumes a continuation at most once, even when both the reply block and the error handler fire.
private final class OnceResumer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

/// Talks to the root helper over XPC. The connection is created on first use,
/// verified against `requirement`, and recreated after it is invalidated.
public final class XPCHelperClient: HelperControlling, @unchecked Sendable {
    private let machServiceName: String
    private let requirement: String
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init(machServiceName: String, requirement: String) {
        self.machServiceName = machServiceName
        self.requirement = requirement
    }

    public func enable(lowPowerOnBattery: Bool) async throws {
        try await sendForError { proxy, reply in proxy.enable(lowPowerOnBattery: lowPowerOnBattery, reply: reply) }
    }

    public func disable() async throws {
        try await sendForError { proxy, reply in proxy.disable(reply: reply) }
    }

    public func setLowPowerOnBattery(_ on: Bool) async throws {
        try await sendForError { proxy, reply in proxy.setLowPowerOnBattery(on, reply: reply) }
    }

    public func heartbeat() async throws -> Bool {
        try await sendForFlag { proxy, reply in proxy.heartbeat(reply: reply) }
    }

    public func isEnabled() async throws -> Bool {
        try await sendForFlag { proxy, reply in proxy.status(reply: reply) }
    }

    // MARK: - Plumbing

    private func sendForError(
        _ call: @escaping (WakeupHelperXPC, @escaping @Sendable (String?) -> Void) -> Void
    ) async throws {
        let message: String? = try await send(call)
        if let message { throw HelperClientError.helper(message) }
    }

    private func sendForFlag(
        _ call: @escaping (WakeupHelperXPC, @escaping @Sendable (Bool) -> Void) -> Void
    ) async throws -> Bool {
        try await send(call)
    }

    private func send<Value: Sendable>(
        _ call: @escaping (WakeupHelperXPC, @escaping @Sendable (Value) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceResumer<Value>(continuation)
            let object = currentConnection().remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: HelperClientError.connection(error.localizedDescription))
            }
            guard let proxy = object as? WakeupHelperXPC else {
                once.resume(throwing: HelperClientError.connection("The helper proxy has an unexpected type."))
                return
            }
            call(proxy) { once.resume(returning: $0) }
        }
    }

    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let new = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: WakeupHelperXPC.self)
            new.setCodeSigningRequirement(requirement)
            let id = ObjectIdentifier(new)
            new.invalidationHandler = { [weak self] in self?.drop(id) }
            new.resume()
            connection = new
            return new
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        lock.withLock {
            if let connection, ObjectIdentifier(connection) == id { self.connection = nil }
        }
    }
}
