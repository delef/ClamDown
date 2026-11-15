import Foundation
import ClamDownShared

/// Decides when to tell the user that ClamDown has stopped controlling the fans: one menu line while the helper
/// reports stopped, and one notification per stop. A retry in progress and an idle helper (Only With Lid Closed
/// with the lid open) are not shown. Only control that is really back, the helper controlling and holding the
/// fans, ends a stop; idle in the middle of a stop does not, so the same stop never notifies twice.
public struct FanAlert: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case none
        /// Show this line. `notify` is true once per stop.
        case show(line: String, notify: Bool)
        case clear
    }

    /// The line on show, while a stop lasts.
    public private(set) var line: String?

    public init() {}

    /// Feed every cooling status the app reads. Nil (the helper did not answer) changes nothing.
    public mutating func update(_ status: CoolingStatus?) -> Change {
        guard let status else { return .none }
        switch status.control {
        case .stopped:
            let new = Self.line(reason: status.problem)
            guard new != line else { return .none }
            let first = line == nil
            line = new
            return .show(line: new, notify: first)
        case .controlling where status.isControlling:
            return reset()
        case .controlling, .retrying, .idle:
            return .none
        }
    }

    /// Forgets the stop, for example when the mode or fan control is switched off. The next stop notifies again.
    public mutating func reset() -> Change {
        guard line != nil else { return .none }
        line = nil
        return .clear
    }

    /// "ClamDown is not controlling the fans: <reason>. macOS has them."
    /// The helper's reasons are whole sentences, sometimes with raw error text; here they become part of one.
    public static func line(reason: String?) -> String {
        guard let clause = clause(from: reason) else { return String(localized: "ClamDown is not controlling the fans. macOS has them.") }
        return String(localized: "ClamDown is not controlling the fans: \(clause). macOS has them.")
    }

    /// The reason on one line, without its closing full stop, starting in lower case unless it starts with a name.
    public static func clause(from reason: String?) -> String? {
        guard let reason else { return nil }
        var text = reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = text.last, last == "." || last == "…" || last == " " {
            text.removeLast()
        }
        guard let first = text.first else { return nil }
        let firstWord = text.prefix { $0.isLetter || $0.isNumber || $0 == "/" }
        guard !keepsCapital(firstWord) else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// Names the helper's reasons can start with. Acronyms and words like "ClamDown" are caught by their inner capitals.
    private static let names: Set<Substring> = ["Mac", "Apple", "I"]

    private static func keepsCapital(_ word: Substring) -> Bool {
        names.contains(word) || word.dropFirst().contains { $0.isUppercase }
    }
}
