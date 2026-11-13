import Foundation
import Testing
@testable import ClamDownAppKit

/// Waiting for macOS to remove the old helper is a suspension point, so a second button press can arrive
/// in the middle of the first. Each test presses twice.
@MainActor @Suite struct OverlappingActionsTests {
    @Test func secondTurnOnDuringHelperUpdateIsIgnored() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "old")
        async let first: Void = rig.controller.toggle()
        async let second: Void = rig.controller.toggle()
        _ = await (first, second)
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.helper.enableCalls.count == 1)
        #expect(rig.controller.state == .on)
    }

    /// The second Turn On would read "not registered" while the old helper is still being removed and register
    /// at once: the very thing macOS refuses.
    @Test func turnOnDuringUpdateDoesNotRegisterIntoTheRemoval() async {
        let rig = Rig(availability: [.ready, .notRegistered, .notRegistered, .ready],
                      helperFingerprint: "new", installedFingerprint: "old")
        async let first: Void = rig.controller.toggle()
        async let second: Void = rig.controller.toggle()
        _ = await (first, second)
        #expect(rig.registrar.registerCount == 1)
    }

    @Test func reinstallPressedTwiceRunsOnce() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "new")
        async let first: Void = rig.controller.reinstallHelper()
        async let second: Void = rig.controller.reinstallHelper()
        _ = await (first, second)
        #expect(rig.registrar.unregisterCount == 1)
        #expect(rig.registrar.registerCount == 1)
    }

    /// "Turn On For 2 hours" waited for approval. The second press must not replace it with the timer setting (Never).
    @Test func turnOnNowPressedTwiceKeepsTheRememberedDuration() async {
        let rig = Rig(availability: [.requiresApproval, .ready])
        await rig.controller.turnOn(for: .seconds(7200))
        let model = SetupModel(presentation: SetupPresentation(mode: .helperOnly, step: .helper), controller: rig.controller,
                               store: FakeSetupStore(), notifications: FakeNotificationAuthorizer())
        async let first: Void = model.turnOnNow()
        async let second: Void = model.turnOnNow()
        _ = await (first, second)
        #expect(rig.helper.enableCalls.count == 1)
        #expect(rig.controller.offAt == rig.clock.now.addingTimeInterval(7200))
    }

    @Test func preparingWhileBusySaysSoInsteadOfRegisteringAgain() async {
        let rig = Rig(helperFingerprint: "new", installedFingerprint: "old")
        let turnOn = Task { await rig.controller.toggle() }
        // Wait until the Turn On is inside the helper update, where it waits for the old helper to be removed.
        // Its next step needs the main actor, which this test holds until `prepareHelper()` has answered.
        while rig.registrar.unregisterCount == 0 { await Task.yield() }
        let result = await rig.controller.prepareHelper()
        await turnOn.value
        #expect(result == .failed("ClamDown is still setting up the helper. Try again in a moment."))
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.controller.state == .on)
    }

    /// Approval arrives after a Turn On that waited for it, and the user never presses Turn On again.
    @Test func approvalClearsTheAttentionMark() async {
        let rig = Rig(availability: [.requiresApproval, .ready])
        await rig.controller.toggle()
        rig.controller.refreshHelperAvailability()
        #expect(rig.controller.state == .off)
        #expect(!rig.controller.needsAttention)
    }

    /// The macOS notification prompt sits in a screen corner and is easy to miss. While it waits for an answer,
    /// the other buttons of the assistant must keep working.
    @Test func unansweredNotificationPromptDoesNotBlockTheHelperButton() async {
        let rig = Rig(availability: [.notRegistered, .notRegistered, .ready])
        let prompt = HeldPrompt()
        let model = SetupModel(presentation: SetupPresentation(mode: .full, step: .helper), controller: rig.controller,
                               store: FakeSetupStore(), notifications: prompt)
        let asking = Task { await model.allowNotifications() }
        await prompt.waitUntilShown()
        await model.allowHelper()
        #expect(model.helper == .ready)
        #expect(rig.registrar.registerCount == 1)
        prompt.answer()
        await asking.value
    }
}

/// A notification prompt nobody has answered yet.
private final class HeldPrompt: NotificationAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var answerContinuation: CheckedContinuation<Void, Never>?
    private var shownContinuation: CheckedContinuation<Void, Never>?
    private var shown = false

    func permission() async -> NotificationPermission { .notAsked }

    func requestPermission() async -> NotificationPermission {
        await withCheckedContinuation { continuation in
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                answerContinuation = continuation
                shown = true
                defer { shownContinuation = nil }
                return shownContinuation
            }
            waiter?.resume()
        }
        return .allowed
    }

    func waitUntilShown() async {
        await withCheckedContinuation { continuation in
            let alreadyShown = lock.withLock { () -> Bool in
                if !shown { shownContinuation = continuation }
                return shown
            }
            if alreadyShown { continuation.resume() }
        }
    }

    func answer() {
        lock.withLock { answerContinuation }?.resume()
    }
}
