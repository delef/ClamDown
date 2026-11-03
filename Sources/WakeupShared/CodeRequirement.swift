public enum CodeRequirement {
    /// Builds a code-signing requirement that pins one signing identifier and one Team ID.
    /// Returns nil for any input that could change the requirement's syntax.
    public static func make(identifier: String, teamID: String) -> String? {
        guard isValidIdentifier(identifier), isValidTeamID(teamID) else { return nil }
        return #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(teamID)""#
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { isDigit($0) || isUpper($0) || isLower($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
    }

    private static func isValidTeamID(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { isDigit($0) || isUpper($0) }
    }

    private static func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
    private static func isUpper(_ b: UInt8) -> Bool { b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z") }
    private static func isLower(_ b: UInt8) -> Bool { b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z") }
}
