import Foundation
import Testing
@testable import ClamDownAppKit

@MainActor @Suite struct SetupModelTests {
    private func makeModel(
        _ rig: Rig,
        mode: SetupMode = .full,
        step: SetupStep = .welcome,
        store: FakeSetupStore = FakeSetupStore(),
        notifications: FakeNotificationAuthorizer = FakeNotificationAuthorizer()
    ) -> SetupModel {
        SetupModel(presentation: SetupPresentation(mode: mode, step: step), controller: rig.controller,
                   store: store, notifications: notifications)
    }

    @Test func continueIsBlockedUntilHelperIsReady() async {
        let model = makeModel(Rig(availability: [.requiresApproval, .ready]), step: .helper)
        #expect(!model.canContinue)
        await model.refreshHelper()
        #expect(model.canContinue)
    }

    /// Seen on a real Mac: the user allowed the helper, macOS said "allowed", and launchd still never started it.
    /// The step said "Allowed" and setup ended with everything apparently on. Only a helper that answers counts.
    @Test func anAllowedHelperThatNeverAnswersIsNotReady() async {
        let rig = Rig(availability: [.ready])
        rig.helper.with { $0.statusError = HelperClientError.connection("The helper did not answer.") }
        let store = FakeSetupStore()
        let model = makeModel(rig, step: .helper, store: store)
        #expect(await model.refreshHelper() == false)
        #expect(model.helperRun == .silent)
        #expect(!model.canContinue)
        #expect(!store.completed)

        rig.jobs.says(.spawnFailed(reason: "78: EX_CONFIG"))
        await model.refreshHelper()
        #expect(model.helperRun == .startFailed)

        rig.jobs.says(.running)
        rig.helper.with { $0.statusError = nil }
        #expect(await model.refreshHelper() == true)
        #expect(model.helperRun == .answers)
        #expect(model.canContinue)
        #expect(store.completed)
    }

    @Test func advanceStopsAtHelperStepUntilReady() {
        let model = makeModel(Rig(availability: [.requiresApproval]))
        model.advance()
        model.advance()
        #expect(model.step == .helper)
    }

    @Test func advanceWalksAllStepsAndMarksCompleteAtDone() async {
        let store = FakeSetupStore()
        let model = makeModel(Rig(), store: store)
        // The window asks the helper once a second; until it has answered, the Helper step cannot be passed.
        await model.refreshHelper()
        store.completed = false
        var seen = [model.step]
        for _ in 0..<3 {
            model.advance()
            seen.append(model.step)
        }
        #expect(seen == [.welcome, .helper, .notifications, .startup])
        #expect(!store.completed)
        model.advance()
        #expect(model.step == .done)
        #expect(store.completed)
        #expect(!model.canContinue)
    }

    @Test func allowHelperOpensLoginItemsWhenApprovalIsNeeded() async {
        let rig = Rig(availability: [.notRegistered, .notRegistered, .requiresApproval])
        rig.registrar.registerError = HelperClientError.helper("Operation not permitted")
        let model = makeModel(rig, step: .helper)
        await model.allowHelper()
        #expect(rig.registrar.openApprovalCount == 1)
        #expect(model.helper == .requiresApproval)
        #expect(model.helperError == nil)
        #expect(!model.canContinue)
    }

    @Test func allowHelperFailureThenTryAgainClearsError() async {
        let rig = Rig(availability: [.notRegistered, .notRegistered, .notRegistered, .notRegistered, .ready])
        rig.registrar.registerError = HelperClientError.helper("boom")
        let store = FakeSetupStore()
        let model = makeModel(rig, step: .helper, store: store)
        await model.allowHelper()
        #expect(model.helperError == "boom")
        #expect(!model.canContinue)
        #expect(rig.registrar.openApprovalCount == 0)

        rig.registrar.registerError = nil
        await model.allowHelper()
        #expect(model.helperError == nil)
        #expect(model.helper == .ready)
        #expect(model.canContinue)
        #expect(store.completed)
    }

    @Test func refreshReportsTheMomentHelperBecomesReady() async {
        let store = FakeSetupStore()
        let model = makeModel(Rig(availability: [.requiresApproval, .requiresApproval, .ready, .ready]),
                              step: .helper, store: store)
        #expect(await model.refreshHelper() == false)
        #expect(!store.completed)
        #expect(await model.refreshHelper() == true)
        #expect(store.completed)
        #expect(await model.refreshHelper() == false)
    }

    @Test func allowingNotificationsTurnsTheSettingOn() async {
        var settings = Settings()
        settings.notificationsEnabled = false
        let rig = Rig(settings: settings)
        let authorizer = FakeNotificationAuthorizer(.notAsked, afterRequest: .allowed)
        let model = makeModel(rig, step: .notifications, notifications: authorizer)
        await model.allowNotifications()
        #expect(model.notifications == .allowed)
        #expect(authorizer.requestCount == 1)
        #expect(rig.controller.settings.notificationsEnabled)
    }

    @Test func deniedNotificationsLeaveSettingAlone() async {
        var settings = Settings()
        settings.notificationsEnabled = false
        let rig = Rig(settings: settings)
        let model = makeModel(rig, step: .notifications,
                              notifications: FakeNotificationAuthorizer(.notAsked, afterRequest: .denied))
        await model.allowNotifications()
        #expect(model.notifications == .denied)
        #expect(!rig.controller.settings.notificationsEnabled)
    }

    /// Denied before, so the only way is System Settings. Going there from the assistant is asking for notifications
    /// just as much as pressing "Allow Notifications".
    @Test func allowingInSystemSettingsTurnsTheSettingOn() async {
        var settings = Settings()
        settings.notificationsEnabled = false
        let rig = Rig(settings: settings)
        let authorizer = FakeNotificationAuthorizer(.denied)
        let model = makeModel(rig, step: .notifications, notifications: authorizer)
        await model.refreshNotifications()
        model.openedNotificationSettings()
        authorizer.changeInSystemSettings(to: .allowed)
        await model.refreshNotifications()
        #expect(model.notifications == .allowed)
        #expect(rig.controller.settings.notificationsEnabled)
    }

    /// Permission was there all along and the user had switched the setting off on purpose. Opening the assistant
    /// must not switch it back on.
    @Test func existingPermissionDoesNotOverrideASettingSwitchedOff() async {
        var settings = Settings()
        settings.notificationsEnabled = false
        let rig = Rig(settings: settings)
        let model = makeModel(rig, step: .notifications, notifications: FakeNotificationAuthorizer(.allowed))
        await model.refreshNotifications()
        await model.refreshNotifications()
        #expect(model.notifications == .allowed)
        #expect(!rig.controller.settings.notificationsEnabled)
    }

    /// The user looked at System Settings and left notifications off.
    @Test func visitingSystemSettingsWithoutAllowingChangesNothing() async {
        var settings = Settings()
        settings.notificationsEnabled = false
        let rig = Rig(settings: settings)
        let model = makeModel(rig, step: .notifications, notifications: FakeNotificationAuthorizer(.denied))
        model.openedNotificationSettings()
        await model.refreshNotifications()
        #expect(model.notifications == .denied)
        #expect(!rig.controller.settings.notificationsEnabled)
    }

    @Test func refreshNotificationsReadsWithoutAsking() async {
        let authorizer = FakeNotificationAuthorizer(.denied)
        let model = makeModel(Rig(), notifications: authorizer)
        await model.refreshNotifications()
        #expect(model.notifications == .denied)
        #expect(authorizer.requestCount == 0)
    }

    @Test func turnOnNowFinishesTheRememberedRequest() async {
        let rig = Rig(availability: [.requiresApproval, .requiresApproval, .ready])
        await rig.controller.turnOn(for: .seconds(7200))
        let model = makeModel(rig, mode: .helperOnly, step: .helper)
        await model.turnOnNow()
        #expect(rig.controller.state == .on)
        #expect(rig.controller.offAt == rig.clock.now.addingTimeInterval(7200))
    }

    /// The Turn On that sent the user to System Settings finishes by itself once the helper works.
    @Test func rememberedTurnOnFinishesWhenTheHelperStartsWorking() async {
        let rig = Rig(availability: [.requiresApproval])
        await rig.controller.turnOn(for: .seconds(7200))
        let model = makeModel(rig, mode: .helperOnly, step: .helper)
        #expect(rig.controller.state == .needsApproval)

        rig.registrar.nowAnswers(.ready)
        await model.refreshHelper()

        #expect(rig.controller.state == .on)
        #expect(rig.controller.offAt == rig.clock.now.addingTimeInterval(7200))
        #expect(rig.controller.pendingTurnOn == nil)
    }

    /// ClamDown was switched off in Login Items. After the user turns it on there, launchd still keeps the old job,
    /// which cannot start, so coming back to the app registers the helper afresh once and finishes the Turn On.
    @Test func comingBackFromLoginItemsFinishesTheTurnOn() async {
        let rig = Rig(helperFingerprint: "this build", installedFingerprint: "this build")
        rig.helper.with { $0.statusError = HelperClientError.connection("The helper did not answer.") }
        rig.helper.with { $0.enableError = HelperClientError.connection("The helper did not answer.") }
        rig.jobs.says(.spawnFailed(reason: "78: EX_CONFIG"))
        await rig.controller.turnOn(for: .seconds(7200))
        let model = makeModel(rig, mode: .helperOnly, step: .helper)
        await model.refreshHelper()
        #expect(model.helperRun == .startFailed)

        model.openLoginItems()
        #expect(rig.registrar.openApprovalCount == 1)
        // The user turns ClamDown on in Login Items; only a fresh registration replaces the old job.
        rig.pauser.whilePaused = { [registrar = rig.registrar, helper = rig.helper, jobs = rig.jobs] _ in
            guard registrar.unregisterCount == 2 else { return }
            jobs.says(.running)
            helper.with {
                $0.statusError = nil
                $0.enableError = nil
            }
        }
        await model.returnedToTheApp()

        #expect(rig.controller.state == .on)
        #expect(rig.controller.offAt == rig.clock.now.addingTimeInterval(7200))
        #expect(model.helperRun == .answers)
    }

    @Test func comingBackWithoutGoingToLoginItemsChangesNothing() async {
        let rig = Rig(helperFingerprint: "this build", installedFingerprint: "this build")
        rig.helper.with { $0.statusError = HelperClientError.connection("The helper did not answer.") }
        rig.jobs.says(.spawnFailed(reason: "78: EX_CONFIG"))
        let model = makeModel(rig, mode: .helperOnly, step: .helper)
        await model.refreshHelper()

        await model.returnedToTheApp()

        #expect(rig.registrar.unregisterCount == 0)
        #expect(model.helperRun == .startFailed)
    }

    @Test func closingDropsRememberedTurnOn() async {
        let rig = Rig(availability: [.requiresApproval])
        await rig.controller.turnOn(for: .seconds(7200))
        let model = makeModel(rig, mode: .helperOnly, step: .helper)
        model.closed()
        #expect(rig.controller.pendingTurnOn == nil)
    }

    @Test func helperOnlyModeHasNoBackAndNoNext() {
        let model = makeModel(Rig(), mode: .helperOnly, step: .helper)
        #expect(model.steps == [.helper])
        #expect(!model.canGoBack)
        #expect(!model.canContinue)
        model.back()
        model.advance()
        #expect(model.step == .helper)
    }

    @Test func backReturnsToThePreviousStep() {
        let model = makeModel(Rig(), step: .notifications)
        #expect(model.canGoBack)
        model.back()
        #expect(model.step == .helper)
    }
}
