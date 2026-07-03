import Foundation

/// Coalesces bursts of triggers into a single trailing-edge action.
///
/// Built for the "routing edit → core reload" path: routing surfaces persist
/// on every gesture (the DNS page commits per keystroke), and each commit must
/// not restart the core individually. `schedule` (re)arms a quiet window; the
/// action runs only once the window elapses with no further `schedule` call,
/// so a burst of edits collapses into one reload carrying the final state. The
/// latest scheduled action wins; superseded ones are discarded unrun.
///
/// MainActor-bound to match `AppState`: `schedule`/`cancel` and the action all
/// run on the main actor, so arming, superseding, and firing can never race.
/// The sleep is injectable so tests control the window's elapse explicitly
/// instead of depending on wall-clock timing.
@MainActor
public final class Debouncer {
    /// Suspends for the given number of nanoseconds. Must follow the
    /// `Task.sleep` contract: throw (or return with the task cancelled) when
    /// the surrounding task is cancelled mid-sleep.
    public typealias Sleep = @Sendable (_ nanoseconds: UInt64) async throws -> Void

    private let quietWindowNanoseconds: UInt64
    private let sleep: Sleep
    /// The task waiting out the current quiet window, if any.
    private var pending: Task<Void, Never>?

    /// Creates a debouncer driven by the real clock (`Task.sleep`).
    ///
    /// Deliberately a convenience initializer rather than a default argument
    /// on the designated one: a cross-module default-argument expression of
    /// this closure type is evaluated in the caller and trips a task-allocator
    /// crash ("freed pointer was not the last allocation") in the current
    /// toolchain. Forming the closure inside the module is safe.
    public convenience init(quietWindow: TimeInterval) {
        self.init(quietWindow: quietWindow, sleep: { try await Task.sleep(nanoseconds: $0) })
    }

    /// - Parameters:
    ///   - quietWindow: Seconds of silence required after the last `schedule`
    ///     before the action fires. Negative values clamp to zero.
    ///   - sleep: The suspension primitive; injected by tests.
    public init(quietWindow: TimeInterval, sleep: @escaping Sleep) {
        self.quietWindowNanoseconds = UInt64(max(0, quietWindow) * 1_000_000_000)
        self.sleep = sleep
    }

    deinit {
        // The pending task only holds `self` weakly, so a debouncer can be
        // dropped with its window still open; the orphaned action must not
        // fire into a dead owner.
        pending?.cancel()
    }

    /// Whether an action is waiting for its quiet window to elapse.
    public var isPending: Bool { pending != nil }

    /// (Re)arms the quiet window with `action` as the trailing action. Any
    /// previously pending action is discarded without running — the newest
    /// call always carries the freshest state.
    public func schedule(_ action: @escaping @MainActor () async -> Void) {
        pending?.cancel()
        let window = quietWindowNanoseconds
        let sleep = sleep
        pending = Task { @MainActor [weak self] in
            do {
                try await sleep(window)
            } catch {
                return  // Cancelled mid-sleep: superseded or cancelled.
            }
            // An injected sleep may return normally even when cancelled;
            // re-check so a superseded action can never slip through. Both
            // `schedule`/`cancel` and this task run on the main actor, so a
            // task that passes this check is necessarily the current pending.
            guard !Task.isCancelled else { return }
            self?.pending = nil
            await action()
        }
    }

    /// Drops any pending action without running it. Idempotent.
    public func cancel() {
        pending?.cancel()
        pending = nil
    }
}
