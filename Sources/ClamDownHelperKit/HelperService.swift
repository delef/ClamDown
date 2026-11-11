import Foundation
import ClamDownShared

public final class HelperService: NSObject, ClamDownHelperXPC {
    private let core: HelperCore

    public init(core: HelperCore) {
        self.core = core
    }

    public func enable(lowPowerOnBattery: Bool, reply: @escaping @Sendable (String?) -> Void) {
        let core = core
        Task { reply(await Self.errorText { try await core.enable(lowPowerOnBattery: lowPowerOnBattery) }) }
    }

    public func disable(reply: @escaping @Sendable (String?) -> Void) {
        let core = core
        Task { reply(await Self.errorText { try await core.disable() }) }
    }

    public func setLowPowerOnBattery(_ on: Bool, reply: @escaping @Sendable (String?) -> Void) {
        let core = core
        Task { reply(await Self.errorText { try await core.setLowPowerOnBattery(on) }) }
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
        Task {
            reply(await Self.errorText {
                try await core.setFanPolicy(JSONDecoder().decode(FanPolicy.self, from: policy))
            })
        }
    }

    public func coolingStatus(reply: @escaping @Sendable (Data?) -> Void) {
        let core = core
        Task { reply(try? JSONEncoder().encode(await core.coolingStatus())) }
    }

    private static func errorText(_ body: @Sendable () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch {
            return String(describing: error)
        }
    }
}
