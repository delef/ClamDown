import Testing
@testable import ClamDownAppKit

@Suite struct UpdateFindingTests {
    private func finding(_ events: UpdateFinding.Event...) -> UpdateFinding {
        var finding = UpdateFinding()
        for event in events { finding.handle(event) }
        return finding
    }

    @Test func nothingFoundAtFirst() {
        #expect(UpdateFinding().foundVersion == nil)
        #expect(UpdateFinding().reminderVersion == nil)
    }

    /// Check Now, then "Remind Me Later": About still has to say the version is waiting.
    @Test func aVersionFoundByCheckNowOutlivesTheSession() {
        let f = finding(.found("0.1.4", userInitiated: true, shownBySparkle: true), .sessionFinished)
        #expect(f.foundVersion == "0.1.4")
        #expect(f.reminderVersion == nil)
    }

    /// A gentle scheduled reminder: the menu offers "Update to X…" and About shows the version.
    @Test func aQuietScheduledFindIsAReminderToo() {
        let f = finding(.found("0.1.4", userInitiated: false, shownBySparkle: false))
        #expect(f.foundVersion == "0.1.4")
        #expect(f.reminderVersion == "0.1.4")
    }

    /// The menu's "Update to X…" opens Sparkle's window: the reminder is gone, the version is still waiting.
    @Test func userAttentionEndsOnlyTheReminder() {
        let f = finding(.found("0.1.4", userInitiated: false, shownBySparkle: false), .userAttention)
        #expect(f.foundVersion == "0.1.4")
        #expect(f.reminderVersion == nil)
    }

    @Test func aSessionEndEndsTheReminderButKeepsTheVersion() {
        let f = finding(.found("0.1.4", userInitiated: false, shownBySparkle: false), .sessionFinished)
        #expect(f.foundVersion == "0.1.4")
        #expect(f.reminderVersion == nil)
    }

    /// A scheduled find that Sparkle shows itself (immediate focus) needs no reminder in the menu.
    @Test func aScheduledFindSparkleShowsIsNoReminder() {
        let f = finding(.found("0.1.4", userInitiated: false, shownBySparkle: true))
        #expect(f.foundVersion == "0.1.4")
        #expect(f.reminderVersion == nil)
    }

    @Test func aLaterCheckThatFindsNothingClearsEverything() {
        let f = finding(.found("0.1.4", userInitiated: false, shownBySparkle: false), .noUpdateFound)
        #expect(f.foundVersion == nil)
        #expect(f.reminderVersion == nil)
    }

    @Test func installingClearsEverything() {
        let f = finding(.found("0.1.4", userInitiated: true, shownBySparkle: true), .installing)
        #expect(f.foundVersion == nil)
        #expect(f.reminderVersion == nil)
    }

    @Test func aNewerFindReplacesTheOlder() {
        let f = finding(.found("0.1.4", userInitiated: true, shownBySparkle: true), .sessionFinished,
                        .found("0.1.5", userInitiated: false, shownBySparkle: false))
        #expect(f.foundVersion == "0.1.5")
        #expect(f.reminderVersion == "0.1.5")
    }
}
