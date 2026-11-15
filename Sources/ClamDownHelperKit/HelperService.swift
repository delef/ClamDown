import Foundation
import ClamDownShared

public final class HelperService: NSObject, ClamDownHelperXPC {
    private let core: HelperCore
    /// This connection, as the owner of a mode it switches on.
    public let connection = UUID()

    public init(core: HelperCore) {
        self.core = core
    }

    public func enable(lowPowerOnBattery: Bool, reply: @escaping @Sendable (String?) -> Void) {
        let core = core
        let connection = connection
        Self.run(reply) { try await core.enable(lowPowerOnBattery: lowPowerOnBattery, owner: connection) }
    }

    public func disable(reply: @escaping @Sendable (String?) -> Void) {
        let core = core
        Self.run(reply) { try await core.disable() }
    }

    public func restoreOriginalSettings(reply: @escaping @Sendable (String?) -> Void) {
        let core = core
        Self.run(reply) { try await core.restoreOriginalSettings() }
    }

    public func setLowPowerOnBattery(_ on: Bool, reply: @escaping @Sendable (String?) -> Void) {
        let core = core
        Self.run(reply) { try await core.setLowPowerOnBattery(on) }
    }

    public func heartbeat(reply: @escaping @Sendable (Bool) -> Void) {
        let core = core
        Task { reply(await core.heartbeat()) }
    }

    public func status(reply: @escaping @Sendable (Bool) -> Void) {
        let core = core
        Task { reply(await core.isEnabled) }
    }

    public func setFanPolicy(_ policy: Data, reply: @escaping @Sendable (String?) -> Void) {
        let core = core
        Self.run(reply) { try await core.setFanPolicy(JSONDecoder().decode(FanPolicy.self, from: policy)) }
    }

    public func coolingStatus(reply: @escaping @Sendable (Data?) -> Void) {
        let core = core
        Task { reply(try? JSONEncoder().encode(await core.coolingStatus())) }
    }

    /// Runs `body` in a task and replies with nil on success or the error's description.
    /// One flat task with no nested closure call: older compilers' region-based isolation checker
    /// rejects `Task { reply(await helper { ... }) }`.
    private static func run(_ reply: @escaping @Sendable (String?) -> Void,
                            _ body: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await body()
                reply(nil)
            } catch {
                reply(String(describing: error))
            }
        }
    }
}
