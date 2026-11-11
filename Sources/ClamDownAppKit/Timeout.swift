import Foundation

/// Resumes its continuation at most once, whichever caller gets there first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let taken = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        taken?.resume()
    }
}

/// Runs `operation` and returns when it finishes or after `limit`, whichever comes first.
///
/// A task group would not do: it waits for every child, and a child that ignores cancellation
/// (a pending XPC reply, for example) would hold the caller past the limit.
/// On timeout the operation is cancelled, but whether it stops is up to the operation.
public func awaitingAtMost(_ limit: Duration, _ operation: @escaping @Sendable () async -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let once = Once(continuation)
        let work = Task {
            await operation()
            once.resume()
        }
        Task {
            try? await Task.sleep(for: limit)
            once.resume()
            work.cancel()
        }
    }
}
