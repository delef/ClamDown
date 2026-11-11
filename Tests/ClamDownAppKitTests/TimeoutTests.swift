import Foundation
import Testing
@testable import ClamDownAppKit

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

@Suite struct TimeoutTests {
    @Test func returnsAfterTheLimitWhenTheOperationIgnoresCancellation() async {
        // An operation that never finishes and never checks for cancellation, like a wedged XPC reply.
        let elapsed = await ContinuousClock().measure {
            await awaitingAtMost(.milliseconds(100)) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
                }
            }
        }
        #expect(elapsed < .seconds(2))
    }

    @Test func returnsAsSoonAsTheOperationFinishes() async {
        let elapsed = await ContinuousClock().measure {
            await awaitingAtMost(.seconds(30)) {}
        }
        #expect(elapsed < .seconds(2))
    }

    @Test func runsTheOperation() async {
        let flag = Flag()
        await awaitingAtMost(.seconds(5)) { flag.raise() }
        #expect(flag.isRaised)
    }
}
