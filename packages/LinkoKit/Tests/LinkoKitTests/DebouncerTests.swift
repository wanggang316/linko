import XCTest
@testable import LinkoKit

/// Tests for the trailing-edge debouncer behind "routing edit → core reload".
/// Time is injected: every debouncer sleep suspends on a `SleepGate` until the
/// test releases it, so the quiet window's elapse is an explicit, deterministic
/// event instead of wall-clock timing. One real-clock test covers the default
/// `Task.sleep` path end to end.
@MainActor
final class DebouncerTests: XCTestCase {

    func testFiresOnceAfterQuietWindowElapses() async {
        let gate = SleepGate()
        let debouncer = Debouncer(quietWindow: 1) { _ in try await gate.sleep() }
        var fired: [String] = []

        debouncer.schedule { fired.append("only") }
        XCTAssertTrue(debouncer.isPending)

        await waitUntil { gate.inFlight == 1 }
        gate.releaseAll()
        await waitUntil { fired.count == 1 }

        XCTAssertEqual(fired, ["only"])
        XCTAssertFalse(debouncer.isPending)
    }

    func testBurstCoalescesToASingleTrailingFire() async {
        let gate = SleepGate()
        let debouncer = Debouncer(quietWindow: 1) { _ in try await gate.sleep() }
        var fired: [String] = []

        // Three back-to-back schedules — the per-keystroke DNS commit shape.
        debouncer.schedule { fired.append("first") }
        debouncer.schedule { fired.append("second") }
        debouncer.schedule { fired.append("third") }

        // Let every task reach its sleep, then end the quiet window for all.
        await waitUntil { gate.inFlight == 3 }
        gate.releaseAll()
        await waitUntil { fired.count == 1 }

        // Only the newest action runs; superseded ones are discarded.
        XCTAssertEqual(fired, ["third"])
        XCTAssertFalse(debouncer.isPending)
    }

    func testNewScheduleMidSleepResetsTheWindow() async {
        let gate = SleepGate()
        let debouncer = Debouncer(quietWindow: 1) { _ in try await gate.sleep() }
        var fired: [String] = []

        debouncer.schedule { fired.append("stale") }
        await waitUntil { gate.inFlight == 1 }

        // A new edit lands while the first window is still open: the window
        // restarts (a fresh sleep begins) and the stale action is dropped.
        debouncer.schedule { fired.append("fresh") }
        await waitUntil { gate.inFlight == 2 }
        gate.releaseAll()
        await waitUntil { fired.count == 1 }

        XCTAssertEqual(fired, ["fresh"])
    }

    func testCancelDropsThePendingAction() async {
        let gate = SleepGate()
        let debouncer = Debouncer(quietWindow: 1) { _ in try await gate.sleep() }
        var fireCount = 0

        debouncer.schedule { fireCount += 1 }
        await waitUntil { gate.inFlight == 1 }

        debouncer.cancel()
        XCTAssertFalse(debouncer.isPending)

        gate.releaseAll()
        await drain()
        XCTAssertEqual(fireCount, 0)
    }

    func testDeinitCancelsThePendingAction() async {
        let gate = SleepGate()
        var fireCount = 0
        var debouncer: Debouncer? = Debouncer(quietWindow: 1) { _ in try await gate.sleep() }

        debouncer?.schedule { fireCount += 1 }
        await waitUntil { gate.inFlight == 1 }

        // The pending task holds its owner weakly, so dropping the debouncer
        // deallocates it mid-window; deinit must cancel the orphaned action.
        debouncer = nil
        gate.releaseAll()
        await drain()
        XCTAssertEqual(fireCount, 0)
    }

    func testCancelWithNothingPendingIsANoOp() {
        let debouncer = Debouncer(quietWindow: 1) { _ in }
        debouncer.cancel()
        XCTAssertFalse(debouncer.isPending)
    }

    func testFiresAgainAfterEachSeparateQuietPeriod() async {
        let gate = SleepGate()
        let debouncer = Debouncer(quietWindow: 1) { _ in try await gate.sleep() }
        var fireCount = 0

        debouncer.schedule { fireCount += 1 }
        await waitUntil { gate.inFlight == 1 }
        gate.releaseAll()
        await waitUntil { fireCount == 1 }

        // A second, separate quiet period fires independently.
        debouncer.schedule { fireCount += 1 }
        await waitUntil { gate.inFlight == 1 }
        gate.releaseAll()
        await waitUntil { fireCount == 2 }

        XCTAssertEqual(fireCount, 2)
    }

    func testSchedulingDuringARunningActionArmsANewWindow() async {
        let gate = SleepGate()
        let debouncer = Debouncer(quietWindow: 1) { _ in try await gate.sleep() }
        var fireCount = 0

        debouncer.schedule {
            fireCount += 1
            // An edit landing while the reload itself runs must arm a new
            // window, not be swallowed by the in-flight action.
            if fireCount == 1 {
                debouncer.schedule { fireCount += 1 }
            }
        }
        await waitUntil { gate.inFlight == 1 }
        gate.releaseAll()
        await waitUntil { gate.inFlight == 1 }
        gate.releaseAll()
        await waitUntil { fireCount == 2 }

        XCTAssertEqual(fireCount, 2)
    }

    func testDefaultSleepFiresOnTheRealClock() async {
        // End-to-end sanity for the real-clock (`Task.sleep`) initializer.
        let debouncer = Debouncer(quietWindow: 0.05)
        var fireCount = 0

        debouncer.schedule { fireCount += 1 }
        XCTAssertTrue(debouncer.isPending)

        await waitUntil(timeout: 5) { fireCount == 1 }
        XCTAssertEqual(fireCount, 1)
        XCTAssertFalse(debouncer.isPending)
    }

    // MARK: - Helpers

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Gives queued main-actor tasks a chance to run to completion.
    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// A controllable stand-in for `Task.sleep`: every debouncer sleep suspends
/// here until the test releases it. Cancelled sleepers are resumed normally
/// on release — the debouncer's own post-sleep cancellation check must
/// discard them, which is exactly the contract under test.
@MainActor
private final class SleepGate {
    private var waiters: [CheckedContinuation<Void, Error>] = []

    /// Number of sleeps currently suspended on the gate.
    var inFlight: Int { waiters.count }

    func sleep() async throws {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    /// Ends every in-flight sleep.
    func releaseAll() {
        let resumable = waiters
        waiters = []
        for waiter in resumable {
            waiter.resume()
        }
    }
}
