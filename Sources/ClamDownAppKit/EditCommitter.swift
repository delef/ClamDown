/// Holds back a burst of small edits, such as arrow-key presses on a chart point, and lets only the last one
/// through after a pause in them. Each commit saves the settings and sends a policy to the helper, so a held
/// key must not do that on every repeat. The view shows each edit at once by itself; only the saving waits.
@MainActor
public final class EditCommitter<Value> {
    /// How long the edits must pause before the last one is committed.
    public static var quiet: Duration { .milliseconds(400) }

    /// The edit waiting to be committed, if any.
    public private(set) var pending: Value?
    private var commit: ((Value) -> Void)?
    private var waiter: Task<Void, Never>?
    private let pause: @MainActor (Duration) async -> Void

    /// `pause` waits for the given time; tests replace it.
    public init(pause: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.pause = pause
    }

    /// Replaces any waiting edit with this one and starts the pause again. `commit` is called with the value
    /// when the pause ends, unless another edit or `flush` comes first.
    public func submit(_ value: Value, commit: @escaping (Value) -> Void) {
        pending = value
        self.commit = commit
        waiter?.cancel()
        waiter = Task { [weak self, pause] in
            await pause(Self.quiet)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Commits the waiting edit now, for example when the point loses focus. Does nothing when none waits.
    public func flush() {
        waiter?.cancel()
        waiter = nil
        guard let value = pending, let commit else { return }
        pending = nil
        self.commit = nil
        commit(value)
    }

    /// Forgets the waiting edit without committing it, for when it no longer applies (the curve it was made on
    /// is not shown any more).
    public func discard() {
        waiter?.cancel()
        waiter = nil
        pending = nil
        commit = nil
    }
}
