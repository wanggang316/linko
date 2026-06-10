import XCTest
@testable import LinkoKit

/// Offline tests for the auto-update interval/scheduling math used by the
/// app's background refresh loop. The `Task.sleep`-driven loop itself lives
/// app-side; this verifies the pure values it depends on, including clamping
/// against a corrupted/too-short configured interval.
final class AutoUpdateScheduleTests: XCTestCase {

    func testSleepNanosecondsForNormalInterval() {
        // 60 minutes -> 60 * 60 * 1e9 ns.
        XCTAssertEqual(AutoUpdateSchedule.sleepNanoseconds(forMinutes: 60), 60 * 60 * 1_000_000_000)
    }

    func testSleepNanosecondsClampsTooShortInterval() {
        // Below the floor (e.g. a corrupted 1) clamps to the 5-minute minimum.
        let expected = UInt64(AppPreferences.minAutoUpdateMinutes) * 60 * 1_000_000_000
        XCTAssertEqual(AutoUpdateSchedule.sleepNanoseconds(forMinutes: 1), expected)
        XCTAssertEqual(AutoUpdateSchedule.sleepNanoseconds(forMinutes: -100), expected)
        XCTAssertEqual(AutoUpdateSchedule.sleepNanoseconds(forMinutes: 0), expected)
    }

    func testSleepNanosecondsAtTheMinimumIsUnclamped() {
        let minutes = AppPreferences.minAutoUpdateMinutes
        XCTAssertEqual(
            AutoUpdateSchedule.sleepNanoseconds(forMinutes: minutes),
            UInt64(minutes) * 60 * 1_000_000_000
        )
    }

    func testSleepSecondsMatchesNanoseconds() {
        for minutes in [5, 30, 60, 1440] {
            let seconds = AutoUpdateSchedule.sleepSeconds(forMinutes: minutes)
            XCTAssertEqual(UInt64(seconds) * 1_000_000_000, AutoUpdateSchedule.sleepNanoseconds(forMinutes: minutes))
        }
    }

    func testSleepSecondsClamps() {
        XCTAssertEqual(
            AutoUpdateSchedule.sleepSeconds(forMinutes: 2),
            AppPreferences.minAutoUpdateMinutes * 60
        )
    }

    func testShouldRunMirrorsEnabledFlag() {
        XCTAssertTrue(AutoUpdateSchedule.shouldRun(enabled: true))
        XCTAssertFalse(AutoUpdateSchedule.shouldRun(enabled: false))
    }

    func testNanosecondsPerMinuteConstant() {
        XCTAssertEqual(AutoUpdateSchedule.nanosecondsPerMinute, 60 * 1_000_000_000)
    }
}
