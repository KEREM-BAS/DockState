import Foundation

/// Coalesces bursts of events (display reconfiguration, sleep/wake) into one action that
/// runs only after things have been quiet for `delay`.
///
/// Displays often appear one by one after wake or when a dock is plugged in; acting on the
/// first event would match against a half-connected setup.
public actor SettleDebouncer {
    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var generation = 0

    public init(delay: Duration) {
        self.delay = delay
    }

    /// Restarts the quiet period; `action` runs once it elapses without another signal.
    public func signal(_ action: @escaping @Sendable () async -> Void) {
        generation += 1
        let mine = generation
        pending?.cancel()
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self.isCurrent(mine) else { return }
            await action()
        }
    }

    public func cancel() {
        generation += 1
        pending?.cancel()
        pending = nil
    }

    private func isCurrent(_ g: Int) -> Bool { g == generation }
}
