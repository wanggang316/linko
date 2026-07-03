import XCTest
@testable import LinkoKit

/// Records every osascript invocation and serves one canned response,
/// optionally after a delay (to drive the timeout path) or as a thrown
/// launch error. Never spawns a real process.
private final class FakeShell: ShellRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executablePath: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []

    var response = ShellResult(exitCode: 0, standardOutput: "", standardError: "")
    /// When > 0, `run` sleeps this long before answering.
    var delay: TimeInterval = 0
    /// When set, `run` throws instead of returning `response`.
    var launchError: Error?

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(executablePath: String, arguments: [String]) throws -> ShellResult {
        lock.lock()
        recorded.append(Invocation(executablePath: executablePath, arguments: arguments))
        lock.unlock()

        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        if let launchError {
            throw launchError
        }
        return response
    }
}

final class BrowserPageReaderTests: XCTestCase {
    private func makeReader(shell: FakeShell, timeout: TimeInterval = 1.0) -> OsascriptBrowserPageReader {
        // Each reader gets an isolated in-flight registry: production shares
        // a process-wide one, but tests must not leak single-flight state
        // (e.g. a deliberately hung FakeShell) across cases.
        OsascriptBrowserPageReader(shell: shell, timeout: timeout, inFlight: .init())
    }

    // MARK: - Dialect dispatch

    func testSafariUsesCurrentTabDialectAndParsesURL() throws {
        let shell = FakeShell()
        shell.response = ShellResult(
            exitCode: 0, standardOutput: "https://example.com/page\n", standardError: ""
        )

        let url = try makeReader(shell: shell).currentPageURL(browserBundleID: "com.apple.Safari")

        XCTAssertEqual(url, "https://example.com/page")
        XCTAssertEqual(shell.invocations, [
            FakeShell.Invocation(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "tell application id \"com.apple.Safari\" to get URL of current tab of front window",
                ]
            ),
        ])
    }

    func testChromiumFamilyUsesActiveTabDialectAndParsesURL() throws {
        let chromiumBundleIDs = [
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "com.brave.Browser",
        ]
        for bundleID in chromiumBundleIDs {
            let shell = FakeShell()
            shell.response = ShellResult(
                exitCode: 0, standardOutput: "https://example.com/\n", standardError: ""
            )

            let url = try makeReader(shell: shell).currentPageURL(browserBundleID: bundleID)

            XCTAssertEqual(url, "https://example.com/", "bundle id: \(bundleID)")
            XCTAssertEqual(shell.invocations, [
                FakeShell.Invocation(
                    executablePath: "/usr/bin/osascript",
                    arguments: [
                        "-e",
                        "tell application id \"\(bundleID)\" to get URL of active tab of front window",
                    ]
                ),
            ], "bundle id: \(bundleID)")
        }
    }

    func testSupportedBundleIDsListsAllFiveBrowsers() {
        XCTAssertEqual(OsascriptBrowserPageReader.supportedBundleIDs, [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "com.brave.Browser",
        ])
    }

    // MARK: - Error taxonomy

    func testUnsupportedBundleIDThrowsWithoutRunningShell() {
        let shell = FakeShell()

        XCTAssertThrowsError(
            try makeReader(shell: shell).currentPageURL(browserBundleID: "org.mozilla.firefox")
        ) { error in
            XCTAssertEqual(
                error as? BrowserPageReadError,
                .unsupportedBrowser(bundleID: "org.mozilla.firefox")
            )
        }
        XCTAssertTrue(shell.invocations.isEmpty, "unsupported browsers must never spawn osascript")
    }

    func testPermissionDeniedIsClassifiedFromTCCErrorCode() {
        let shell = FakeShell()
        shell.response = ShellResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "execution error: Not authorized to send Apple events to Safari. (-1743)"
        )

        XCTAssertThrowsError(
            try makeReader(shell: shell).currentPageURL(browserBundleID: "com.apple.Safari")
        ) { error in
            XCTAssertEqual(error as? BrowserPageReadError, .permissionDenied(browserName: "Safari"))
        }
    }

    func testNoWindowIsClassifiedFromInvalidIndexErrorCode() {
        let shell = FakeShell()
        shell.response = ShellResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "execution error: Google Chrome got an error: Invalid index. (-1719)"
        )

        XCTAssertThrowsError(
            try makeReader(shell: shell).currentPageURL(browserBundleID: "com.google.Chrome")
        ) { error in
            XCTAssertEqual(error as? BrowserPageReadError, .noWindow(browserName: "Google Chrome"))
        }
    }

    func testEmptyOutputThrows() {
        let shell = FakeShell()
        shell.response = ShellResult(exitCode: 0, standardOutput: "\n", standardError: "")

        XCTAssertThrowsError(
            try makeReader(shell: shell).currentPageURL(browserBundleID: "com.apple.Safari")
        ) { error in
            XCTAssertEqual(error as? BrowserPageReadError, .emptyOutput(browserName: "Safari"))
        }
    }

    func testMissingValueOutputIsTreatedAsEmpty() {
        let shell = FakeShell()
        shell.response = ShellResult(exitCode: 0, standardOutput: "missing value\n", standardError: "")

        XCTAssertThrowsError(
            try makeReader(shell: shell).currentPageURL(browserBundleID: "com.brave.Browser")
        ) { error in
            XCTAssertEqual(error as? BrowserPageReadError, .emptyOutput(browserName: "Brave Browser"))
        }
    }

    func testSlowShellHitsTimeout() {
        let shell = FakeShell()
        shell.delay = 0.5
        shell.response = ShellResult(
            exitCode: 0, standardOutput: "https://example.com/\n", standardError: ""
        )

        XCTAssertThrowsError(
            try makeReader(shell: shell, timeout: 0.05)
                .currentPageURL(browserBundleID: "com.apple.Safari")
        ) { error in
            XCTAssertEqual(error as? BrowserPageReadError, .timedOut(browserName: "Safari"))
        }
    }

    func testUnrecognizedFailureIsClassifiedAsScriptFailed() {
        let shell = FakeShell()
        shell.response = ShellResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "execution error: Some other scripting failure. (-2700)"
        )

        XCTAssertThrowsError(
            try makeReader(shell: shell).currentPageURL(browserBundleID: "com.microsoft.edgemac")
        ) { error in
            XCTAssertEqual(
                error as? BrowserPageReadError,
                .scriptFailed(browserName: "Microsoft Edge")
            )
        }
    }

    func testShellLaunchFailureIsClassifiedAsScriptFailed() {
        let shell = FakeShell()
        shell.launchError = CocoaError(.fileNoSuchFile)

        XCTAssertThrowsError(
            try makeReader(shell: shell).currentPageURL(browserBundleID: "company.thebrowser.Browser")
        ) { error in
            XCTAssertEqual(error as? BrowserPageReadError, .scriptFailed(browserName: "Arc"))
        }
    }

    // MARK: - Single flight

    func testSecondReadForSameBrowserFailsFastWhileFirstIsInFlight() {
        let shell = FakeShell()
        shell.delay = 0.5
        shell.response = ShellResult(
            exitCode: 0, standardOutput: "https://example.com/\n", standardError: ""
        )
        let reader = makeReader(shell: shell, timeout: 0.05)

        // The first read times out, but its osascript is still running.
        XCTAssertThrowsError(try reader.currentPageURL(browserBundleID: "com.apple.Safari")) { error in
            XCTAssertEqual(error as? BrowserPageReadError, .timedOut(browserName: "Safari"))
        }

        // A second read of the same browser fails fast — before spawning
        // another osascript that would just stack behind the first.
        XCTAssertThrowsError(try reader.currentPageURL(browserBundleID: "com.apple.Safari")) { error in
            XCTAssertEqual(error as? BrowserPageReadError, .timedOut(browserName: "Safari"))
        }
        XCTAssertEqual(shell.invocations.count, 1, "the in-flight browser must not spawn a second osascript")

        // Single flight is keyed by bundle id: a different browser still
        // spawns its own read.
        XCTAssertThrowsError(try reader.currentPageURL(browserBundleID: "com.google.Chrome"))
        XCTAssertEqual(shell.invocations.count, 2)
    }

    func testCompletedReadReleasesTheSingleFlightSlot() throws {
        let shell = FakeShell()
        shell.response = ShellResult(
            exitCode: 0, standardOutput: "https://example.com/a\n", standardError: ""
        )
        let reader = makeReader(shell: shell)

        XCTAssertEqual(try reader.currentPageURL(browserBundleID: "com.apple.Safari"), "https://example.com/a")
        XCTAssertEqual(try reader.currentPageURL(browserBundleID: "com.apple.Safari"), "https://example.com/a")
        XCTAssertEqual(shell.invocations.count, 2, "a completed read must release its slot for the next one")
    }

    // MARK: - Privacy

    func testErrorDescriptionsNeverLeakScriptOutputOrURL() {
        // stderr deliberately embeds a page URL; no error description may
        // carry the URL or any fragment of the raw script output through.
        let secret = "https://secret.example/account"
        let scenarios: [(stderr: String, expected: BrowserPageReadError)] = [
            (
                "execution error: Not authorized to send Apple events to Safari. \(secret) (-1743)",
                .permissionDenied(browserName: "Safari")
            ),
            (
                "execution error: Safari got an error: Invalid index. \(secret) (-1719)",
                .noWindow(browserName: "Safari")
            ),
            (
                "execution error: \(secret) (-2700)",
                .scriptFailed(browserName: "Safari")
            ),
        ]

        for scenario in scenarios {
            let shell = FakeShell()
            shell.response = ShellResult(
                exitCode: 1, standardOutput: "", standardError: scenario.stderr
            )

            XCTAssertThrowsError(
                try makeReader(shell: shell).currentPageURL(browserBundleID: "com.apple.Safari")
            ) { error in
                guard let readError = error as? BrowserPageReadError else {
                    return XCTFail("expected BrowserPageReadError, got \(type(of: error))")
                }
                XCTAssertEqual(readError, scenario.expected)
                let description = readError.errorDescription ?? ""
                XCTAssertFalse(description.contains(secret), description)
                XCTAssertFalse(description.contains("execution error"), description)
            }
        }
    }

    func testAllErrorDescriptionsCarryOnlyCategoryAndBrowserName() {
        let secretURL = "https://secret.example/account"
        let cases: [BrowserPageReadError] = [
            .unsupportedBrowser(bundleID: "org.mozilla.firefox"),
            .noWindow(browserName: "Safari"),
            .emptyOutput(browserName: "Safari"),
            .permissionDenied(browserName: "Safari"),
            .timedOut(browserName: "Safari"),
            .scriptFailed(browserName: "Safari"),
        ]
        for error in cases {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) must describe itself")
            XCTAssertFalse(description.contains(secretURL))
        }
    }
}
