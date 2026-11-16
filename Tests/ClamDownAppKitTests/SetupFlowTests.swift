import Foundation
import Testing
@testable import ClamDownAppKit

@Suite struct SetupFlowTests {
    @Test func launchShowsFullSetupForNewUser() {
        let expected = SetupPresentation(mode: .full, step: .welcome)
        #expect(SetupFlow.presentation(for: .launch, completed: false, helper: .notRegistered) == expected)
        #expect(SetupFlow.presentation(for: .launch, completed: false, helper: .requiresApproval) == expected)
    }

    @Test func launchIsSilentForExistingUser() {
        #expect(SetupFlow.presentation(for: .launch, completed: false, helper: .ready) == nil)
        #expect(SetupFlow.completesSilently(completed: false, helper: .ready))
    }

    @Test func launchShowsNothingOnceCompleted() {
        #expect(SetupFlow.presentation(for: .launch, completed: true, helper: .requiresApproval) == nil)
        #expect(!SetupFlow.completesSilently(completed: true, helper: .requiresApproval))
        #expect(!SetupFlow.completesSilently(completed: false, helper: .requiresApproval))
    }

    /// A Turn On that sets up or waits for the helper shows it on the Helper step, as one that needs approval does.
    @Test func turnOnProgressOpensHelperStep() {
        #expect(SetupFlow.presentation(for: .turnOnProgress, completed: true, helper: .ready)
            == SetupPresentation(mode: .helperOnly, step: .helper))
        #expect(SetupFlow.presentation(for: .turnOnProgress, completed: false, helper: .ready)
            == SetupPresentation(mode: .full, step: .helper))
    }

    @Test func turnOnOpensHelperStep() {
        #expect(SetupFlow.presentation(for: .turnOnNeedsApproval, completed: false, helper: .requiresApproval)
            == SetupPresentation(mode: .full, step: .helper))
        #expect(SetupFlow.presentation(for: .turnOnNeedsApproval, completed: true, helper: .requiresApproval)
            == SetupPresentation(mode: .helperOnly, step: .helper))
    }

    @Test func menuOpensWelcomeOrHelperOnly() {
        #expect(SetupFlow.presentation(for: .menu, completed: false, helper: .notRegistered)
            == SetupPresentation(mode: .full, step: .welcome))
        #expect(SetupFlow.presentation(for: .menu, completed: true, helper: .requiresApproval)
            == SetupPresentation(mode: .helperOnly, step: .helper))
    }

    @Test func settingsAlwaysOpensFullSetup() {
        #expect(SetupFlow.presentation(for: .settings, completed: true, helper: .ready)
            == SetupPresentation(mode: .full, step: .welcome))
    }

    @Test func stepOrder() {
        #expect(SetupFlow.steps(for: .full) == [.welcome, .helper, .notifications, .startup, .done])
        #expect(SetupFlow.next(after: .welcome, mode: .full) == .helper)
        #expect(SetupFlow.next(after: .startup, mode: .full) == .done)
        #expect(SetupFlow.next(after: .done, mode: .full) == nil)
        #expect(SetupFlow.previous(before: .welcome, mode: .full) == nil)
        #expect(SetupFlow.previous(before: .helper, mode: .full) == .welcome)
    }

    @Test func helperOnlyHasOneStep() {
        #expect(SetupFlow.steps(for: .helperOnly) == [.helper])
        #expect(SetupFlow.next(after: .helper, mode: .helperOnly) == nil)
        #expect(SetupFlow.previous(before: .helper, mode: .helperOnly) == nil)
    }

    @Test func continueWaitsForHelper() {
        #expect(!SetupFlow.canContinue(from: .helper, helper: .requiresApproval, helperAnswers: false))
        #expect(!SetupFlow.canContinue(from: .helper, helper: .notRegistered, helperAnswers: false))
        #expect(SetupFlow.canContinue(from: .helper, helper: .ready, helperAnswers: true))
        #expect(SetupFlow.canContinue(from: .notifications, helper: .notRegistered, helperAnswers: false))
        // Seen on a real Mac: macOS reported the helper allowed while launchd never started it.
        #expect(!SetupFlow.canContinue(from: .helper, helper: .ready, helperAnswers: false))
    }

    @Test func storeRemembersCompletion() throws {
        let suite = "clamdown.tests.setup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!UserDefaultsSetupStore(defaults: defaults).completed)
        UserDefaultsSetupStore(defaults: defaults).completed = true
        #expect(UserDefaultsSetupStore(defaults: defaults).completed)
    }
}
