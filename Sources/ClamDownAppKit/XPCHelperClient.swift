import Foundation
import ClamDownShared

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
/// verified against `requirement`, and replaced by a new one after it fails.
public final class XPCHelperClient: HelperControlling, @unchecked Sendable {
    /// Makes a new connection to the helper, not yet resumed.
    private let connect: @Sendable () -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public convenience init(machServiceName: String, requirement: String) {
        self.init(connect: {
            let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
            connection.setCodeSigningRequirement(requirement)
            return connection
        })
    }

    init(connect: @escaping @Sendable () -> NSXPCConnection) {
        self.connect = connect
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

    public func setFanPolicy(_ policy: FanPolicy) async throws {
        let data = try JSONEncoder().encode(policy)
        try await sendForError { proxy, reply in proxy.setFanPolicy(data, reply: reply) }
    }

    public func coolingStatus() async throws -> CoolingStatus {
        let data: Data? = try await send { proxy, reply in proxy.coolingStatus(reply: reply) }
        guard let data else { throw HelperClientError.helper("The helper could not read the sensors.") }
        do {
            return try JSONDecoder().decode(CoolingStatus.self, from: data)
        } catch {
            throw HelperClientError.helper("The helper sent an unreadable sensor report.")
        }
    }

    // MARK: - Plumbing

    private func sendForError(
        _ call: @escaping (ClamDownHelperXPC, @escaping @Sendable (String?) -> Void) -> Void
    ) async throws {
        let message: String? = try await send(call)
        if let message { throw HelperClientError.helper(message) }
    }

    private func sendForFlag(
        _ call: @escaping (ClamDownHelperXPC, @escaping @Sendable (Bool) -> Void) -> Void
    ) async throws -> Bool {
        try await send(call)
    }

    /// Sends a request, once more on a new connection when the first one turned out dead.
    ///
    /// The connection outlives the helper it was made for: an update replaces the helper, and macOS restarts one
    /// that quit. The first request on such a connection fails without reaching anyone, so asking again is safe.
    /// Every request also sets or reads a state, so one the old helper did receive can be sent again.
    private func send<Value: Sendable>(
        _ call: @escaping (ClamDownHelperXPC, @escaping @Sendable (Value) -> Void) -> Void
    ) async throws -> Value {
        do {
            return try await sendOnce(call)
        } catch HelperClientError.connection {
            return try await sendOnce(call)
        }
    }

    private func sendOnce<Value: Sendable>(
        _ call: @escaping (ClamDownHelperXPC, @escaping @Sendable (Value) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceResumer<Value>(continuation)
            let connection = currentConnection()
            let object = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
                // A connection that failed once is not trusted again: the next request makes a new one.
                if let connection { self?.discard(connection) }
                once.resume(throwing: HelperClientError.connection(Self.noAnswer))
            }
            guard let proxy = object as? ClamDownHelperXPC else {
                once.resume(throwing: HelperClientError.connection("The helper proxy has an unexpected type."))
                return
            }
            call(proxy) { once.resume(returning: $0) }
        }
    }

    /// The system's own text for this is "Couldn't communicate with a helper application", which tells the user nothing.
    static let noAnswer = "The helper did not answer."

    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let new = connect()
            new.remoteObjectInterface = NSXPCInterface(with: ClamDownHelperXPC.self)
            let id = ObjectIdentifier(new)
            new.invalidationHandler = { [weak self] in self?.drop(id) }
            new.resume()
            connection = new
            return new
        }
    }

    private func discard(_ dead: NSXPCConnection) {
        drop(ObjectIdentifier(dead))
        // Outside the lock: invalidating calls the invalidation handler, which takes it.
        dead.invalidate()
    }

    private func drop(_ id: ObjectIdentifier) {
        lock.withLock {
            if let connection, ObjectIdentifier(connection) == id { self.connection = nil }
        }
    }
}
