public enum Identifiers {
    /// Mach service name, launchd label and code-signing identifier of the helper daemon.
    public static func helperLabel(appBundleID: String) -> String {
        appBundleID + ".helper"
    }
}
