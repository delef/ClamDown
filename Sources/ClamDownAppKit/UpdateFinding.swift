/// What Sparkle has found, kept apart from Sparkle's sessions: a found version stays found after the user closes
/// Sparkle's window with "Remind Me Later", until a later check finds nothing or the update is installed.
///
/// Two versions come out of it: `foundVersion` answers "is there an update?" on the About page, and
/// `reminderVersion` is the quiet reminder the menu shows ("Update to X…") for a scheduled check that Sparkle did not
/// show itself.
public struct UpdateFinding: Equatable, Sendable {
    /// What Sparkle reports, as the updater's delegates hear it.
    public enum Event: Equatable, Sendable {
        /// A check found a version. `userInitiated` for Check Now; `shownBySparkle` when Sparkle opens its own
        /// window for it rather than leaving a reminder to the app.
        case found(String, userInitiated: Bool, shownBySparkle: Bool)
        /// The user opened Sparkle's window for the update, for example from the menu's reminder.
        case userAttention
        /// Sparkle's update session ended: installed, skipped, or put off with "Remind Me Later".
        case sessionFinished
        /// A check found no new version.
        case noUpdateFound
        /// The update is about to be installed.
        case installing
    }

    /// The version a check found, until a later check finds nothing or the update is installed.
    public private(set) var foundVersion: String?
    /// The version the menu reminds of: found by a scheduled check that Sparkle left to the app, until the user
    /// opens it or the session ends.
    public private(set) var reminderVersion: String?

    public init() {}

    public mutating func handle(_ event: Event) {
        switch event {
        case .found(let version, let userInitiated, let shownBySparkle):
            foundVersion = version
            reminderVersion = !userInitiated && !shownBySparkle ? version : nil
        case .userAttention, .sessionFinished:
            reminderVersion = nil
        case .noUpdateFound, .installing:
            foundVersion = nil
            reminderVersion = nil
        }
    }
}
