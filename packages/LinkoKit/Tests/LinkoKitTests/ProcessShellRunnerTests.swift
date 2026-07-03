import XCTest
@testable import LinkoKit

/// Tests for `ProcessShellRunner`: normal capture semantics stay intact, and
/// the per-stream output cap turns a runaway/impersonated child into a
/// deterministic failure instead of an unbounded buffer. The cap logic is
/// pinned twice — as a pure drain over an in-memory pipe (injectable limit)
/// and end-to-end against a real process breaching the production cap.
final class ProcessShellRunnerTests: XCTestCase {

    // MARK: - Normal runs (semantics unchanged by the cap)

    func testRunCapturesStdoutAndExitCode() throws {
        let result = try ProcessShellRunner().run(
            executablePath: "/bin/echo", arguments: ["hello"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "hello\n")
        XCTAssertEqual(result.standardError, "")
    }

    func testRunCapturesStderrAndNonzeroExit() throws {
        let result = try ProcessShellRunner().run(
            executablePath: "/bin/sh", arguments: ["-c", "echo oops 1>&2; exit 3"]
        )

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(result.standardError, "oops\n")
    }

    // MARK: - Output cap (end-to-end, real process)

    /// A child pushing more than the cap through stdout must fail the run —
    /// and terminate, rather than deadlock on a reader that stopped reading.
    func testOversizedStdoutFailsTheRun() {
        let oversize = ProcessShellRunner.outputByteLimit + 1
        XCTAssertThrowsError(
            try ProcessShellRunner().run(
                executablePath: "/usr/bin/head",
                arguments: ["-c", String(oversize), "/dev/zero"]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProcessShellRunnerError,
                .outputLimitExceeded(limitBytes: ProcessShellRunner.outputByteLimit)
            )
        }
    }

    /// Output exactly at the cap is not a breach — the failure needs `limit`
    /// *exceeded*, so legitimate maximal output still comes back intact.
    func testOutputExactlyAtTheLimitSucceeds() throws {
        let result = try ProcessShellRunner().run(
            executablePath: "/usr/bin/head",
            arguments: ["-c", String(ProcessShellRunner.outputByteLimit), "/dev/zero"]
        )

        XCTAssertEqual(result.exitCode, 0)
        // NUL bytes decode as UTF-8; the byte count must round-trip in full.
        XCTAssertEqual(result.standardOutput.utf8.count, ProcessShellRunner.outputByteLimit)
    }

    // MARK: - Drain (pure cap logic over an in-memory pipe)

    func testDrainReturnsEverythingUnderTheLimit() {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("abc".utf8))
        pipe.fileHandleForWriting.closeFile()

        var breaches = 0
        let outcome = ProcessShellRunner.drain(
            pipe.fileHandleForReading, limit: 1024, onLimitBreach: { breaches += 1 }
        )

        XCTAssertEqual(outcome.data, Data("abc".utf8))
        XCTAssertFalse(outcome.breachedLimit)
        XCTAssertEqual(breaches, 0)
    }

    /// Past the limit the drain reports the breach exactly once, keeps none
    /// of the hostile bulk, and still reads through to EOF (so the runner's
    /// barrier and `waitUntilExit` can never hang on a half-read pipe).
    func testDrainPastTheLimitBreachesOnceAndDiscards() {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(repeating: 0x41, count: 2048))
        pipe.fileHandleForWriting.closeFile()

        var breaches = 0
        let outcome = ProcessShellRunner.drain(
            pipe.fileHandleForReading, limit: 1024, onLimitBreach: { breaches += 1 }
        )

        XCTAssertTrue(outcome.breachedLimit)
        XCTAssertTrue(outcome.data.isEmpty)
        XCTAssertEqual(breaches, 1)
    }
}
