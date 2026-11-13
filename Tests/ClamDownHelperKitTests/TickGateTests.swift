import Foundation
import Testing
@testable import ClamDownHelperKit

/// Holds a task until the test opens it.
private actor Latch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@Suite struct TickGateTests {
    /// Waits, briefly, until the gate's last tick has finished.
    private func settle(_ gate: TickGate) async throws {
        for _ in 0..<2000 where gate.isBusy { try await Task.sleep(for: .milliseconds(1)) }
    }

    @Test func aSlowTickMakesTheNextOnesSkipInsteadOfQueueing() async throws {
        let gate = TickGate()
        let latch = Latch()
        let runs = Counter()
        #expect(gate.start { runs.add(); await latch.wait() })
        #expect(!gate.start { runs.add() })
        #expect(!gate.start { runs.add() })
        await latch.open()
        try await settle(gate)
        #expect(!gate.isBusy)
        #expect(runs.value == 1)
    }

    @Test func theNextTickRunsOnceThePreviousOneHasFinished() async throws {
        let gate = TickGate()
        let runs = Counter()
        #expect(gate.start { runs.add() })
        try await settle(gate)
        #expect(gate.start { runs.add() })
        try await settle(gate)
        #expect(runs.value == 2)
    }
}
