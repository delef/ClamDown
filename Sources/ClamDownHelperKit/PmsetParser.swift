public enum PmsetParser {
    /// Value of the `SleepDisabled` line in `pmset -g` output. macOS prints that line only once `disablesleep` has been
    /// set, so a missing line in a complete listing (one with its `Currently in use:` section) is the default, off.
    /// Nil when the line is there but is not exactly `SleepDisabled 0` or `SleepDisabled 1`, and when the output is not
    /// a listing at all (empty, or an error message), so such output can never read as "sleep is not disabled".
    public static func sleepDisabled(fromGlobal output: String) -> Bool? {
        var complete = false
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.first == "SleepDisabled" {
                return fields.count == 2 ? flag(fields[1]) : nil
            }
            if line.hasPrefix("Currently in use:") { complete = true }
        }
        return complete ? false : nil
    }

    /// Value of `lowpowermode` in the "Battery Power:" section of `pmset -g custom` output.
    /// Other sections are ignored. Nil when the section or the key is missing.
    public static func batteryLowPowerMode(fromCustom output: String) -> Bool? {
        var inBatterySection = false
        for line in output.split(whereSeparator: \.isNewline) {
            if let first = line.first, first != " ", first != "\t" {
                inBatterySection = line.hasPrefix("Battery Power:")
                continue
            }
            guard inBatterySection else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count == 2, fields[0] == "lowpowermode" {
                return flag(fields[1])
            }
        }
        return nil
    }

    private static func flag(_ text: Substring) -> Bool? {
        switch text {
        case "1": true
        case "0": false
        default: nil
        }
    }
}
