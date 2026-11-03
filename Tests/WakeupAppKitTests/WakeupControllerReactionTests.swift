import Testing
@testable import WakeupAppKit

@MainActor @Suite struct WakeupControllerReactionTests {
    private func snapshot(_ percent: Int?, onBattery: Bool, thermal: ThermalLevel = .nominal) -> SystemSnapshot {
        SystemSnapshot(batteryPercent: percent, isOnBattery: onBattery, thermal: thermal)
    }

    /// A rig whose switch is already on.
    private func onRig(snapshot: SystemSnapshot = .calm) async -> Rig {
        let rig = Rig(snapshot: snapshot)
        await rig.controller.toggle()
        return rig
    }

    // MARK: start

    @Test func startDisablesLeftoverHelperState() async {
        let rig = Rig()
        rig.helper.with { $0.enabled = true }
        await rig.controller.start()
        #expect(rig.helper.disableCount == 1)
        #expect(rig.monitor.startCount == 1)
    }

    @Test func startLeavesHelperAloneWhenItIsOff() async {
        let rig = Rig()
        await rig.controller.start()
        #expect(rig.helper.disableCount == 0)
    }

    // MARK: system changes

    @Test func batteryAtCutoffTurnsOffAndNotifies() async {
        let rig = await onRig()
        rig.monitor.current = snapshot(10, onBattery: true)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.helper.disableCount == 1)
        #expect(rig.activity.endCount == 1)
        let body = rig.notifier.posted.last?.body ?? ""
        #expect(body.contains("battery at 10%") && body.contains("The Mac can sleep now."))
    }

    @Test func lowBatteryWhileChargingStaysOn() async {
        let rig = await onRig()
        rig.monitor.current = snapshot(5, onBattery: false)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .on)
        #expect(rig.helper.disableCount == 0)
    }

    @Test func thermalSeriousTurnsOff() async {
        let rig = await onRig()
        rig.monitor.current = snapshot(80, onBattery: true, thermal: .serious)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.notifier.posted.last?.body.contains("Mac is hot (serious)") == true)
    }

    @Test func noBatteryMacStaysOn() async {
        let rig = await onRig()
        rig.monitor.current = snapshot(nil, onBattery: false)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .on)
    }

    @Test func systemChangeWhenOffDoesNothing() async {
        let rig = Rig(snapshot: snapshot(5, onBattery: true))
        await rig.controller.handleSystemChange()
        #expect(rig.helper.disableCount == 0 && rig.helper.heartbeatCount == 0)
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test func wakeResyncTurnsOffWhenHelperAlreadyReset() async {
        let rig = await onRig()
        rig.helper.with { $0.heartbeatResult = .success(false) }
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
    }

    @Test func failedAutoOffStillEndsActivityAndStopsHeartbeats() async {
        let rig = await onRig()
        rig.helper.with { $0.disableError = HelperClientError.connection("gone") }
        rig.monitor.current = snapshot(10, onBattery: true)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.activity.endCount == 1)
        #expect(rig.controller.notice?.contains("will reset") == true)
        await rig.controller.sendHeartbeat()
        #expect(rig.helper.heartbeatCount == 0)
    }

    // MARK: periodic tick

    @Test func periodicTickReevaluatesCutoffsWithoutAnyNotification() async throws {
        let rig = Rig(heartbeatInterval: .milliseconds(20))
        await rig.controller.toggle()
        rig.monitor.current = snapshot(10, onBattery: true)  // no handleSystemChange() call: a missed notification
        for _ in 0..<100 where rig.controller.state == .on {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(rig.controller.state == .off)
        #expect(rig.helper.disableCount == 1)
    }

    @Test func periodicTickSendsHeartbeatWhileAllowed() async throws {
        let rig = Rig(heartbeatInterval: .milliseconds(20))
        await rig.controller.toggle()
        for _ in 0..<100 where rig.helper.heartbeatCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(rig.helper.heartbeatCount > 0)
        #expect(rig.controller.state == .on)
    }

    // MARK: heartbeat

    @Test func heartbeatTrueKeepsOn() async {
        let rig = await onRig()
        await rig.controller.sendHeartbeat()
        #expect(rig.controller.state == .on)
        #expect(rig.helper.heartbeatCount == 1)
    }

    @Test func heartbeatFalseTurnsOffAndNotifies() async {
        let rig = await onRig()
        rig.helper.with { $0.heartbeatResult = .success(false) }
        await rig.controller.sendHeartbeat()
        #expect(rig.controller.state == .off)
        #expect(rig.notifier.posted.last?.body == "Turned off: the helper stopped the mode.")
        #expect(rig.activity.endCount == 1)
    }

    @Test func heartbeatThrowTurnsOff() async {
        let rig = await onRig()
        rig.helper.with { $0.heartbeatResult = .failure(HelperClientError.connection("x")) }
        await rig.controller.sendHeartbeat()
        #expect(rig.controller.state == .off)
    }

    // MARK: settings

    @Test func updateSettingsClampsAndSaves() async {
        let rig = Rig()
        var settings = rig.controller.settings
        settings.batteryCutoffPercent = 500
        await rig.controller.updateSettings(settings)
        #expect(rig.controller.settings.batteryCutoffPercent == 50)
        #expect(rig.store.saved.last?.batteryCutoffPercent == 50)
    }

    @Test func updateSettingsForwardsLowPowerWhenOn() async {
        let rig = await onRig()
        var settings = rig.controller.settings
        settings.autoLowPowerOnBattery = false
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.lowPowerCalls == [false])
    }

    @Test func updateSettingsWhenOffDoesNotTouchHelper() async {
        let rig = Rig()
        var settings = rig.controller.settings
        settings.autoLowPowerOnBattery = false
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.lowPowerCalls.isEmpty)
    }

    @Test func raisingCutoffAboveCurrentBatteryTurnsOff() async {
        let rig = await onRig(snapshot: snapshot(40, onBattery: true))
        var settings = rig.controller.settings
        settings.batteryCutoffPercent = 50
        await rig.controller.updateSettings(settings)
        #expect(rig.controller.state == .off)
    }

    // MARK: shutdown

    @Test func shutdownDisablesWhenOn() async {
        let rig = await onRig()
        await rig.controller.shutdown()
        #expect(rig.helper.disableCount == 1)
        #expect(rig.monitor.stopCount == 1)
    }

    @Test func shutdownWhenOffDoesNotCallHelper() async {
        let rig = Rig()
        await rig.controller.shutdown()
        #expect(rig.helper.disableCount == 0)
        #expect(rig.monitor.stopCount == 1)
    }
}
