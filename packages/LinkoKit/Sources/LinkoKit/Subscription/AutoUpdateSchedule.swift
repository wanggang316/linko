import Foundation

/// Pure scheduling math for the background subscription auto-update loop.
/// Separated from the app's `Task`-driven scheduler so the interval/clamping
/// logic is unit-testable offline (no real clock, no `Task.sleep`). The app's
/// `AutoUpdateScheduler` consumes these values to drive its background loop.
public enum AutoUpdateSchedule {
    /// Nanoseconds in one minute, as used by `Task.sleep(nanoseconds:)`.
    public static let nanosecondsPerMinute: UInt64 = 60 * 1_000_000_000

    /// The sleep interval (in nanoseconds) for the given configured minutes,
    /// clamped to `AppPreferences.minAutoUpdateMinutes` so a corrupted/short
    /// value can never busy-loop the network. Mirrors the production loop.
    public static func sleepNanoseconds(forMinutes minutes: Int) -> UInt64 {
        UInt64(AppPreferences.clampInterval(minutes)) * nanosecondsPerMinute
    }

    /// The seconds form of `sleepNanoseconds`, for callers that prefer
    /// `Duration`/`ContinuousClock` or want a human-readable value in logs.
    public static func sleepSeconds(forMinutes minutes: Int) -> Int {
        AppPreferences.clampInterval(minutes) * 60
    }

    /// Whether the loop should be running at all for the given preferences.
    /// Centralizes the on/off decision so the app's scheduler and any UI
    /// status share one definition.
    public static func shouldRun(enabled: Bool) -> Bool {
        enabled
    }
}
