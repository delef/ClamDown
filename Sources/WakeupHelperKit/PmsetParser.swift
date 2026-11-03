public enum PmsetParser {
    /// Value of the `SleepDisabled` line in `pmset -g` output, or nil when absent.
    public static func sleepDisabled(fromGlobal output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count == 2, fields[0] == "SleepDisabled" {
                return flag(fields[1])
            }
        }
        return nil
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
