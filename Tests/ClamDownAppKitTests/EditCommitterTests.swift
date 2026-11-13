import Foundation
import Testing
@testable import ClamDownAppKit

/// Stands in for waiting: each pause hangs until the test lets it go.
@MainActor
final class HeldPauses {
    private(set) var asked: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var pause: @MainActor (Duration) async -> Void {
        { [self] duration in
            asked.append(duration)
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    /// Ends every pause asked for so far, then lets the waiting work run.
    func releaseAll() async {
        // Let work that was just started reach its pause first.
        for _ in 0..<10 { await Task.yield() }
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
        for _ in 0..<10 { await Task.yield() }
    }
}

@MainActor @Suite struct EditCommitterTests {
    @Test func aBurstCommitsOnlyTheLastValueAfterAPause() async {
        let pauses = HeldPauses()
        let committer = EditCommitter<Int>(pause: pauses.pause)
        var committed: [Int] = []
        for value in 1...3 { committer.submit(value) { committed.append($0) } }
        await Task.yield()
        #expect(committed.isEmpty)
        #expect(committer.pending == 3)
        await pauses.releaseAll()
        #expect(committed == [3])
        #expect(committer.pending == nil)
    }

    @Test func thePauseIsFourTenthsOfASecond() async {
        let pauses = HeldPauses()
        let committer = EditCommitter<Int>(pause: pauses.pause)
        committer.submit(1) { _ in }
        for _ in 0..<5 { await Task.yield() }
        #expect(pauses.asked == [.milliseconds(400)])
        #expect(EditCommitter<Int>.quiet == .milliseconds(400))
    }

    @Test func flushCommitsAtOnceAndOnlyOnce() async {
        let pauses = HeldPauses()
        let committer = EditCommitter<Int>(pause: pauses.pause)
        var committed: [Int] = []
        committer.submit(7) { committed.append($0) }
        committer.flush()
        #expect(committed == [7])
        await pauses.releaseAll()
        #expect(committed == [7])
    }

    @Test func flushWithNothingPendingDoesNothing() {
        let committer = EditCommitter<Int>(pause: { _ in })
        committer.flush()
        #expect(committer.pending == nil)
    }

    @Test func theLatestCommitActionIsUsed() async {
        let pauses = HeldPauses()
        let committer = EditCommitter<Int>(pause: pauses.pause)
        var first: [Int] = [], second: [Int] = []
        committer.submit(1) { first.append($0) }
        committer.submit(2) { second.append($0) }
        await pauses.releaseAll()
        #expect(first.isEmpty && second == [2])
    }

    @Test func aPressAfterACommitStartsANewPause() async {
        let pauses = HeldPauses()
        let committer = EditCommitter<Int>(pause: pauses.pause)
        var committed: [Int] = []
        committer.submit(1) { committed.append($0) }
        await pauses.releaseAll()
        committer.submit(2) { committed.append($0) }
        await Task.yield()
        #expect(committed == [1])
        await pauses.releaseAll()
        #expect(committed == [1, 2])
    }

    @Test func discardForgetsTheWaitingEdit() async {
        let pauses = HeldPauses()
        let committer = EditCommitter<Int>(pause: pauses.pause)
        var committed: [Int] = []
        committer.submit(1) { committed.append($0) }
        committer.discard()
        await pauses.releaseAll()
        committer.flush()
        #expect(committed.isEmpty && committer.pending == nil)
    }
}
