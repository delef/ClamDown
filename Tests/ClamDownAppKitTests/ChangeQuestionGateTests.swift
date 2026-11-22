import Foundation
import Testing
@testable import ClamDownAppKit

/// Who is asked about a change after an update, and how often.
@MainActor @Suite struct ChangeQuestionGateTests {
    private let id = "menuBarIcon.lid.0.1.3"

    private func store() -> UserDefaultsAskedQuestionsStore {
        let name = "clamdown-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return UserDefaultsAskedQuestionsStore(defaults: defaults)
    }

    @Test func anUpdatedUserWithTheOldBehaviourIsAskedOnce() {
        let asked = store()
        #expect(ChangeQuestionGate(asked: asked, isUpdate: true).shouldAsk(id, showIf: true))
        #expect(!ChangeQuestionGate(asked: asked, isUpdate: true).shouldAsk(id, showIf: true))
    }

    /// A new user starts with the new behaviour; a later launch, once settings are stored, must not ask either.
    @Test func aNewInstallIsNeverAsked() {
        let asked = store()
        #expect(!ChangeQuestionGate(asked: asked, isUpdate: false).shouldAsk(id, showIf: true))
        #expect(!ChangeQuestionGate(asked: asked, isUpdate: true).shouldAsk(id, showIf: true))
    }

    /// Someone who already took the new behaviour is not asked, and not later after switching back either.
    @Test func aUserWithTheNewBehaviourIsNotAsked() {
        let asked = store()
        #expect(!ChangeQuestionGate(asked: asked, isUpdate: true).shouldAsk(id, showIf: false))
        #expect(!ChangeQuestionGate(asked: asked, isUpdate: true).shouldAsk(id, showIf: true))
    }

    @Test func eachQuestionIsAskedOnItsOwn() {
        let gate = ChangeQuestionGate(asked: store(), isUpdate: true)
        #expect(gate.shouldAsk(id, showIf: true))
        #expect(gate.shouldAsk("another.change", showIf: true))
    }
}
