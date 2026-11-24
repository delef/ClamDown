public enum Identifiers {
    /// The system log's subsystem for the app and the helper: `log show --predicate 'subsystem == "app.clamdown"'`.
    /// Fixed, not the bundle identifier, so one predicate finds every build's entries.
    public static let logSubsystem = "app.clamdown"

    /// Mach service name, launchd label and code-signing identifier of the helper daemon.
    public static func helperLabel(appBundleID: String) -> String {
        appBundleID + ".helper"
    }
}
