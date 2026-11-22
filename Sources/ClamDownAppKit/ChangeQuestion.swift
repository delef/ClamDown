import Foundation

/// A choice the app offers once after an update changed how something behaves: keep the old behaviour or take the
/// new one. The code that brings in a change asks about it where it is, with what to do for each answer; nothing
/// lists the questions in one place (owner, 2026-11-22: "механизм создаем общий, мы явно будем часто делать
/// изменения, и нужно будет опрашивать"; "просто показываем с помощью функции, а у фукции делаем коллбэки с
/// обработкой двух исходов"; "окно показывается один раз").
public struct ChangeQuestion: Sendable {
    /// What the window shows besides the text.
    public enum Illustration: Equatable, Sendable {
        /// The menu bar icon in the old and the new style; the window shows the new one first.
        case menuBarIcons(old: MenuBarIconStyle, new: MenuBarIconStyle)
    }

    /// Stable and never reused: the record of what was asked keeps it for good.
    public let id: String
    public let title: String
    public let message: String
    public let illustration: Illustration?
    /// The button that takes the new behaviour; the window's default.
    public let newChoice: String
    /// The button that keeps the old behaviour.
    public let oldChoice: String

    public init(id: String, title: String, message: String, illustration: Illustration? = nil,
                newChoice: String, oldChoice: String) {
        self.id = id
        self.title = title
        self.message = message
        self.illustration = illustration
        self.newChoice = newChoice
        self.oldChoice = oldChoice
    }
}

/// Decides whether a change question is shown: once per id, and only to a user who came from an older build and
/// still has the old behaviour. A new user starts with the new behaviour and is never asked.
@MainActor
public final class ChangeQuestionGate {
    private let asked: AskedQuestionsStoring
    private let isUpdate: Bool

    /// `isUpdate` is false on a new install: no settings were stored before this launch.
    public init(asked: AskedQuestionsStoring, isUpdate: Bool) {
        self.asked = asked
        self.isUpdate = isUpdate
    }

    /// True when the question is to be shown now. The id is recorded whatever the answer, so the question never
    /// comes back: not after it was shown (even if the window is closed unanswered), not for a new user, not for one
    /// who already has the new behaviour.
    /// `showIf` is the caller's own condition, normally "this user still has the old behaviour".
    public func shouldAsk(_ id: String, showIf condition: Bool) -> Bool {
        guard !asked.asked.contains(id) else { return false }
        asked.asked.insert(id)
        return isUpdate && condition
    }
}

/// Remembers which change questions were asked, or found not to apply, so none is asked twice.
public protocol AskedQuestionsStoring: AnyObject {
    var asked: Set<String> { get set }
}

public final class UserDefaultsAskedQuestionsStore: AskedQuestionsStoring {
    private static let key = "changeQuestions.asked.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var asked: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.key) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.key) }
    }
}
