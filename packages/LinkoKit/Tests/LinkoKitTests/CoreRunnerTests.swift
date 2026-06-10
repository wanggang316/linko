import XCTest
@testable import LinkoKit

final class CoreRunnerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private var configURL: URL { temporaryDirectory.appendingPathComponent("config.json") }
    private var logURL: URL { temporaryDirectory.appendingPathComponent("logs/core.log") }

    func testInitialStateIsStopped() {
        let runner = CoreRunner()
        XCTAssertEqual(runner.state, .stopped)
        XCTAssertFalse(runner.isRunning)
    }

    func testStartWithMissingBinaryThrows() {
        let runner = CoreRunner()
        let missing = temporaryDirectory.appendingPathComponent("no-such-binary")
        XCTAssertThrowsError(
            try runner.start(binaryURL: missing, configFileURL: configURL, logFileURL: logURL)
        ) { error in
            XCTAssertEqual(
                error as? CoreRunnerError,
                .binaryNotExecutable(path: missing.path)
            )
        }
        XCTAssertEqual(runner.state, .stopped)
    }

    func testStartWithNonExecutableFileThrows() throws {
        let runner = CoreRunner()
        let plainFile = temporaryDirectory.appendingPathComponent("plain.txt")
        try Data("not a binary".utf8).write(to: plainFile)
        XCTAssertThrowsError(
            try runner.start(binaryURL: plainFile, configFileURL: configURL, logFileURL: logURL)
        )
    }

    func testStopWhenNotRunningIsSafe() {
        let runner = CoreRunner()
        runner.stop()
        runner.stop()
        XCTAssertEqual(runner.state, .stopped)
    }

    func testUnexpectedExitTransitionsToFailedAndWritesLog() throws {
        // /bin/echo ignores the "run -c <config>" arguments, prints them to the
        // log, and exits immediately — an unexpected exit from CoreRunner's view.
        let runner = CoreRunner()
        try runner.start(
            binaryURL: URL(fileURLWithPath: "/bin/echo"),
            configFileURL: configURL,
            logFileURL: logURL
        )

        let deadline = Date().addingTimeInterval(5)
        while runner.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard case let .failed(reason) = runner.state else {
            return XCTFail("expected .failed, got \(runner.state)")
        }
        XCTAssertTrue(reason.contains("unexpectedly"))

        let logContents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(logContents.contains(configURL.path))
    }

    func testStopTerminatesRunningProcess() throws {
        // `/bin/cat run -c <config>` blocks reading the (existing, empty-ish)
        // files... cat would exit on missing "run" file, so use a script that
        // sleeps to simulate a long-running core.
        let script = temporaryDirectory.appendingPathComponent("fake-core.sh")
        try Data("#!/bin/sh\nsleep 60\n".utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )

        let runner = CoreRunner()
        try runner.start(binaryURL: script, configFileURL: configURL, logFileURL: logURL)
        guard case let .running(pid) = runner.state else {
            return XCTFail("expected .running, got \(runner.state)")
        }
        XCTAssertGreaterThan(pid, 0)
        XCTAssertTrue(runner.isRunning)

        // Starting again while running must throw.
        XCTAssertThrowsError(
            try runner.start(binaryURL: script, configFileURL: configURL, logFileURL: logURL)
        ) { error in
            XCTAssertEqual(error as? CoreRunnerError, .alreadyRunning)
        }

        runner.stop()

        // stop() transitions state synchronously; no polling needed.
        XCTAssertEqual(runner.state, .stopped)
        XCTAssertFalse(runner.isRunning)
    }

    func testImmediateRestartAfterStopDoesNotThrowAlreadyRunning() throws {
        // Regression: stop() used to delegate the state reset to the
        // termination handler, so stop()+start() back to back (the restart
        // path) intermittently threw .alreadyRunning.
        let script = temporaryDirectory.appendingPathComponent("fake-core.sh")
        try Data("#!/bin/sh\nsleep 60\n".utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )

        let runner = CoreRunner()
        for _ in 0..<3 {
            try runner.start(binaryURL: script, configFileURL: configURL, logFileURL: logURL)
            XCTAssertTrue(runner.isRunning)
            runner.stop()
            XCTAssertEqual(runner.state, .stopped)
        }
    }

    func testOnStateChangeReportsUnexpectedExit() throws {
        let runner = CoreRunner()
        let failed = expectation(description: "core failure reported")
        runner.onStateChange = { state in
            if case .failed = state {
                failed.fulfill()
            }
        }
        try runner.start(
            binaryURL: URL(fileURLWithPath: "/bin/echo"),
            configFileURL: configURL,
            logFileURL: logURL
        )
        wait(for: [failed], timeout: 5)
    }
}
