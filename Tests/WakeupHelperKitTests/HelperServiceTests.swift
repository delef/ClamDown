import Foundation
import Testing
@testable import WakeupHelperKit

@Suite struct HelperServiceTests {
    private func make() -> (HelperService, FakeRunner) {
        let runner = FakeRunner(batteryLowPower: false)
        let core = HelperCore(runner: runner, store: FakeStore())
        return (HelperService(core: core), runner)
    }

    private func errorReply(_ body: (@escaping @Sendable (String?) -> Void) -> Void) async -> String? {
        await withCheckedContinuation { continuation in body { continuation.resume(returning: $0) } }
    }

    private func flagReply(_ body: (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in body { continuation.resume(returning: $0) } }
    }

    @Test func enableRepliesNilAndRunsCommands() async {
        let (service, runner) = make()
        let reply = await errorReply { service.enable(lowPowerOnBattery: true, reply: $0) }
        #expect(reply == nil)
        #expect(runner.commands.contains(.setSleepDisabled(true)))
    }

    @Test func enableRepliesWithErrorText() async {
        let (service, runner) = make()
        runner.fail(.setSleepDisabled(true))
        let reply = await errorReply { service.enable(lowPowerOnBattery: true, reply: $0) }
        #expect(reply?.isEmpty == false)
    }

    @Test func disableRepliesNilAndTurnsStatusOff() async {
        let (service, _) = make()
        _ = await errorReply { service.enable(lowPowerOnBattery: false, reply: $0) }
        let reply = await errorReply { service.disable(reply: $0) }
        #expect(reply == nil)
        #expect(await flagReply { service.status(reply: $0) } == false)
    }

    @Test func setLowPowerWhenNotEnabledRepliesWithError() async {
        let (service, _) = make()
        let reply = await errorReply { service.setLowPowerOnBattery(true, reply: $0) }
        #expect(reply?.isEmpty == false)
    }

    @Test func heartbeatRepliesFalseWhenNotEnabled() async {
        let (service, _) = make()
        #expect(await flagReply { service.heartbeat(reply: $0) } == false)
    }

    @Test func statusRepliesEnabledAfterEnable() async {
        let (service, _) = make()
        #expect(await flagReply { service.status(reply: $0) } == false)
        _ = await errorReply { service.enable(lowPowerOnBattery: false, reply: $0) }
        #expect(await flagReply { service.status(reply: $0) } == true)
        #expect(await flagReply { service.heartbeat(reply: $0) } == true)
    }
}
