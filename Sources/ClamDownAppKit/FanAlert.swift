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
            let new = Self.line(reason: status.problem, fansAtFullSpeed: status.handBackFailed)
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

    /// "ClamDown is not controlling the fans. macOS has them. <reason>"
    /// The helper's reason follows as its own sentence, so a translation needs no grammar from it.
    /// `fansAtFullSpeed` is true when the hand-back to macOS failed: the helper still holds the fans and runs them
    /// at full speed until the hand-back succeeds, so macOS does not have them.
    public static func line(reason: String?, fansAtFullSpeed: Bool = false) -> String {
        let stopped = fansAtFullSpeed
            ? String(localized: "ClamDown is not controlling the fans. The fans run at full speed.")
            : String(localized: "ClamDown is not controlling the fans. macOS has them.")
        guard let reason = sentence(from: reason) else { return stopped }
        return String.sentences(stopped, reason)
    }

    /// The helper's reason on one line, ending in exactly one full stop. Nil when there is no text.
    /// The helper's reasons are whole sentences, sometimes raw error text with line breaks or an ellipsis.
    public static func sentence(from reason: String?) -> String? {
        guard let reason else { return nil }
        var text = reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = text.last, last == "." || last == "\u{2026}" || last == " " {
            text.removeLast()
        }
        // The case stays as the helper wrote it: "macOS did not hand over fan 2." starts a sentence correctly.
        guard !text.isEmpty else { return nil }
        return text + "."
    }
}
