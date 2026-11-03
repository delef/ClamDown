import Foundation
import WakeupShared

public final class HelperService: NSObject, WakeupHelperXPC {
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

    private static func errorText(_ body: @Sendable () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch {
            return String(describing: error)
        }
    }
}
