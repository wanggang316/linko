import Foundation
import LinkoKit

/// Drives the background subscription auto-update loop. Owns a single detached
/// `Task` that wakes on the configured interval and invokes the supplied
/// refresh closure. The interval/clamping math lives in
/// `LinkoKit.AutoUpdateSchedule` (pure, unit-tested); this type only manages
/// the `Task` lifecycle so it can be cancelled/rescheduled when preferences
/// change. MainActor-bound to match `AppState`.
@MainActor
final class AutoUpdateScheduler {
    private var task: Task<Void, Never>?

    /// Whether a loop is currently scheduled. Exposed for diagnostics/tests.
    var isRunning: Bool { task != nil }

    /// Cancels the running loop, if any. Idempotent.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// (Re)schedules the loop. Cancels any existing loop first, then — when
    /// `enabled` — starts a new one that sleeps for the clamped interval and
    /// calls `refresh` on each tick. The loop exits cleanly on cancellation,
    /// including mid-sleep. `refresh` runs on the main actor.
    func reschedule(
        enabled: Bool,
        intervalMinutes: Int,
        refresh: @escaping @MainActor () async -> Void
    ) {
        stop()
        guard AutoUpdateSchedule.shouldRun(enabled: enabled) else { return }
        let sleepNanoseconds = AutoUpdateSchedule.sleepNanoseconds(forMinutes: intervalMinutes)
        task = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds)
                } catch {
                    // Cancelled mid-sleep: exit the loop without refreshing.
                    return
                }
                if Task.isCancelled { return }
                await refresh()
            }
        }
    }
}
