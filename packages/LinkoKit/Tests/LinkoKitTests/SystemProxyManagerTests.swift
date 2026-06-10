import XCTest
@testable import LinkoKit

/// Records every networksetup invocation and serves canned responses.
private final class FakeShell: ShellRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executablePath: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []

    /// Keyed by the first argument (the networksetup verb) plus optional
    /// service name, e.g. "-getwebproxy Wi-Fi".
    var responses: [String: ShellResult] = [:]

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(executablePath: String, arguments: [String]) throws -> ShellResult {
        lock.lock()
        recorded.append(Invocation(executablePath: executablePath, arguments: arguments))
        lock.unlock()

        let key = arguments.prefix(2).joined(separator: " ")
        if let response = responses[key] ?? responses[arguments.first ?? ""] {
            return response
        }
        return ShellResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}

final class SystemProxyManagerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemProxyManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private var snapshotFileURL: URL {
        temporaryDirectory.appendingPathComponent("system-proxy-snapshot.json")
    }

    private func makeManager(shell: FakeShell) -> SystemProxyManager {
        SystemProxyManager(shell: shell, snapshotFileURL: snapshotFileURL)
    }

    private static let listOutput = """
    An asterisk (*) denotes that a network service is disabled.
    Wi-Fi
    *Bluetooth PAN
    Thunderbolt Bridge
    """

    private static let disabledProxyOutput = """
    Enabled: No
    Server:
    Port: 0
    Authenticated Proxy Enabled: 0
    """

    private static let enabledProxyOutput = """
    Enabled: Yes
    Server: old-proxy.example.com
    Port: 8080
    Authenticated Proxy Enabled: 0
    """

    /// A leftover entry from a crashed previous linko session.
    private static let staleLinkoProxyOutput = """
    Enabled: Yes
    Server: 127.0.0.1
    Port: 7890
    Authenticated Proxy Enabled: 0
    """

    private func makeShell() -> FakeShell {
        let shell = FakeShell()
        shell.responses["-listallnetworkservices"] = ShellResult(
            exitCode: 0, standardOutput: Self.listOutput, standardError: ""
        )
        shell.responses["-getwebproxy"] = ShellResult(
            exitCode: 0, standardOutput: Self.disabledProxyOutput, standardError: ""
        )
        shell.responses["-getsecurewebproxy"] = ShellResult(
            exitCode: 0, standardOutput: Self.disabledProxyOutput, standardError: ""
        )
        shell.responses["-getsocksfirewallproxy"] = ShellResult(
            exitCode: 0, standardOutput: Self.disabledProxyOutput, standardError: ""
        )
        return shell
    }

    func testEnableSetsAllProxiesOnEnabledServicesOnly() throws {
        let shell = makeShell()
        let manager = makeManager(shell: shell)

        try manager.enable(host: "127.0.0.1", port: 7890)
        XCTAssertTrue(manager.isEnabled)

        let setCalls = shell.invocations.filter { $0.arguments.first?.hasPrefix("-set") == true }
        let expected: [[String]] = [
            ["-setwebproxy", "Wi-Fi", "127.0.0.1", "7890"],
            ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "7890"],
            ["-setsocksfirewallproxy", "Wi-Fi", "127.0.0.1", "7890"],
            ["-setwebproxy", "Thunderbolt Bridge", "127.0.0.1", "7890"],
            ["-setsecurewebproxy", "Thunderbolt Bridge", "127.0.0.1", "7890"],
            ["-setsocksfirewallproxy", "Thunderbolt Bridge", "127.0.0.1", "7890"],
        ]
        XCTAssertEqual(setCalls.map(\.arguments), expected)
        XCTAssertTrue(shell.invocations.allSatisfy { $0.executablePath == "/usr/sbin/networksetup" })

        // Disabled "*Bluetooth PAN" must never be touched.
        XCTAssertFalse(shell.invocations.contains { $0.arguments.contains("Bluetooth PAN") })
        XCTAssertFalse(shell.invocations.contains { $0.arguments.contains("*Bluetooth PAN") })
    }

    func testEnableCapturesStateBeforeMutating() throws {
        let shell = makeShell()
        let manager = makeManager(shell: shell)

        try manager.enable(host: "127.0.0.1", port: 7890)

        let verbs = shell.invocations.map { $0.arguments.first ?? "" }
        let firstSetIndex = try XCTUnwrap(verbs.firstIndex { $0.hasPrefix("-set") })
        let lastGetIndex = try XCTUnwrap(verbs.lastIndex { $0.hasPrefix("-get") })
        XCTAssertLessThan(lastGetIndex, firstSetIndex, "all -get snapshots must run before any -set")
    }

    func testDisableTurnsProxiesOffWhenPreviouslyDisabled() throws {
        let shell = makeShell()
        let manager = makeManager(shell: shell)

        try manager.enable(host: "127.0.0.1", port: 7890)
        try manager.disable()
        XCTAssertFalse(manager.isEnabled)

        let stateCalls = shell.invocations.filter {
            $0.arguments.first?.hasSuffix("proxystate") == true
        }
        let expected: [[String]] = [
            ["-setwebproxystate", "Wi-Fi", "off"],
            ["-setsecurewebproxystate", "Wi-Fi", "off"],
            ["-setsocksfirewallproxystate", "Wi-Fi", "off"],
            ["-setwebproxystate", "Thunderbolt Bridge", "off"],
            ["-setsecurewebproxystate", "Thunderbolt Bridge", "off"],
            ["-setsocksfirewallproxystate", "Thunderbolt Bridge", "off"],
        ]
        XCTAssertEqual(stateCalls.map(\.arguments), expected)
    }

    func testDisableRestoresPreviouslyEnabledProxy() throws {
        let shell = makeShell()
        // Wi-Fi web proxy was already pointed at another proxy before enable.
        shell.responses["-getwebproxy Wi-Fi"] = ShellResult(
            exitCode: 0, standardOutput: Self.enabledProxyOutput, standardError: ""
        )
        let manager = makeManager(shell: shell)

        try manager.enable(host: "127.0.0.1", port: 7890)
        try manager.disable()

        let restore = shell.invocations.last {
            $0.arguments.first == "-setwebproxy" && $0.arguments.contains("Wi-Fi")
        }
        XCTAssertEqual(
            restore?.arguments,
            ["-setwebproxy", "Wi-Fi", "old-proxy.example.com", "8080"]
        )
        // The Wi-Fi web proxy must not be turned off, only restored.
        XCTAssertFalse(shell.invocations.contains {
            $0.arguments == ["-setwebproxystate", "Wi-Fi", "off"]
        })
        // Other proxy kinds on Wi-Fi were disabled before, so they go off.
        XCTAssertTrue(shell.invocations.contains {
            $0.arguments == ["-setsecurewebproxystate", "Wi-Fi", "off"]
        })
    }

    func testEnableThrowsAndRollsBackWhenNetworksetupFails() {
        let shell = makeShell()
        // First proxy kind sets fine; the second fails midway through enable.
        shell.responses["-setsecurewebproxy"] = ShellResult(
            exitCode: 5, standardOutput: "", standardError: "boom"
        )
        let manager = makeManager(shell: shell)

        XCTAssertThrowsError(try manager.enable(host: "127.0.0.1", port: 7890)) { error in
            guard case let .commandFailed(_, exitCode, stderr)? = error as? SystemProxyError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertEqual(exitCode, 5)
            XCTAssertEqual(stderr, "boom")
        }
        XCTAssertFalse(manager.isEnabled)

        // The Wi-Fi web proxy was already repointed at linko before the
        // failure; the rollback must turn it back off (its snapshot).
        XCTAssertTrue(shell.invocations.contains {
            $0.arguments == ["-setwebproxystate", "Wi-Fi", "off"]
        })
        // Nothing left to recover on next launch.
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotFileURL.path))
    }

    func testEnableThrowsWhenNoEnabledServices() {
        let shell = FakeShell()
        shell.responses["-listallnetworkservices"] = ShellResult(
            exitCode: 0,
            standardOutput: "An asterisk (*) denotes that a network service is disabled.\n*Everything Off",
            standardError: ""
        )
        let manager = makeManager(shell: shell)

        XCTAssertThrowsError(try manager.enable(host: "127.0.0.1", port: 7890)) { error in
            XCTAssertEqual(error as? SystemProxyError, .noEnabledNetworkServices)
        }
    }

    func testDisableWithoutEnableDoesNothing() throws {
        let shell = FakeShell()
        let manager = makeManager(shell: shell)
        try manager.disable()
        XCTAssertTrue(shell.invocations.isEmpty)
        XCTAssertFalse(manager.isEnabled)
    }

    // MARK: - Snapshot persistence (crash recovery)

    func testEnablePersistsSnapshotBeforeMutatingAndDisableRemovesIt() throws {
        let shell = makeShell()
        // Make the very first -set fail so we can prove the snapshot file
        // already existed before any mutation was attempted.
        shell.responses["-setwebproxy"] = ShellResult(
            exitCode: 1, standardOutput: "", standardError: "denied"
        )
        let failingManager = makeManager(shell: shell)
        XCTAssertThrowsError(try failingManager.enable(host: "127.0.0.1", port: 7890))
        // (The rollback then removes the file again; tested separately.)

        let okShell = makeShell()
        let manager = makeManager(shell: okShell)
        try manager.enable(host: "127.0.0.1", port: 7890)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: snapshotFileURL.path),
            "snapshot must be on disk while the proxy is enabled"
        )

        try manager.disable()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: snapshotFileURL.path),
            "snapshot must be cleaned up after a graceful disable"
        )
    }

    func testRestorePersistedSnapshotRestoresAfterSimulatedCrash() throws {
        let shell = makeShell()
        shell.responses["-getwebproxy Wi-Fi"] = ShellResult(
            exitCode: 0, standardOutput: Self.enabledProxyOutput, standardError: ""
        )
        let crashedManager = makeManager(shell: shell)
        try crashedManager.enable(host: "127.0.0.1", port: 7890)
        // Simulated crash: the manager instance is discarded without disable();
        // only the on-disk snapshot survives.

        let freshShell = FakeShell()
        let freshManager = makeManager(shell: freshShell)
        let restored = try freshManager.restorePersistedSnapshotIfPresent()
        XCTAssertTrue(restored)

        // The pre-crash Wi-Fi web proxy comes back; everything else goes off.
        XCTAssertTrue(freshShell.invocations.contains {
            $0.arguments == ["-setwebproxy", "Wi-Fi", "old-proxy.example.com", "8080"]
        })
        XCTAssertTrue(freshShell.invocations.contains {
            $0.arguments == ["-setsocksfirewallproxystate", "Wi-Fi", "off"]
        })
        XCTAssertTrue(freshShell.invocations.contains {
            $0.arguments == ["-setwebproxystate", "Thunderbolt Bridge", "off"]
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotFileURL.path))

        // A second call finds nothing to do.
        let again = try freshManager.restorePersistedSnapshotIfPresent()
        XCTAssertFalse(again)
    }

    func testRestorePersistedSnapshotWithoutFileIsNoOp() throws {
        let shell = FakeShell()
        let manager = makeManager(shell: shell)
        XCTAssertFalse(try manager.restorePersistedSnapshotIfPresent())
        XCTAssertTrue(shell.invocations.isEmpty)
    }

    func testEnableTreatsStaleLinkoEntryAsPreviouslyOff() throws {
        // A crashed session left Wi-Fi pointed at 127.0.0.1:7890. Re-enabling
        // must not snapshot that as the "previous" state, or disable() would
        // faithfully restore the broken proxy.
        let shell = makeShell()
        shell.responses["-getwebproxy Wi-Fi"] = ShellResult(
            exitCode: 0, standardOutput: Self.staleLinkoProxyOutput, standardError: ""
        )
        let manager = makeManager(shell: shell)

        try manager.enable(host: "127.0.0.1", port: 7890)
        try manager.disable()

        // The stale linko entry must be turned off, never restored.
        XCTAssertTrue(shell.invocations.contains {
            $0.arguments == ["-setwebproxystate", "Wi-Fi", "off"]
        })
        // Exactly one set to 127.0.0.1:7890 (from enable); a second one would
        // mean disable() "restored" the broken linko proxy.
        let linkoSets = shell.invocations.filter {
            $0.arguments == ["-setwebproxy", "Wi-Fi", "127.0.0.1", "7890"]
        }
        XCTAssertEqual(linkoSets.count, 1)
    }

    func testEnableWhileEnabledKeepsOriginalSnapshot() throws {
        let shell = makeShell()
        shell.responses["-getwebproxy Wi-Fi"] = ShellResult(
            exitCode: 0, standardOutput: Self.enabledProxyOutput, standardError: ""
        )
        let manager = makeManager(shell: shell)

        try manager.enable(host: "127.0.0.1", port: 7890)
        let getCountAfterFirstEnable = shell.invocations.filter {
            $0.arguments.first?.hasPrefix("-get") == true
        }.count

        // Second enable (e.g. port change) must not re-snapshot: that would
        // capture linko's own settings and poison the restore path.
        try manager.enable(host: "127.0.0.1", port: 7891)
        let getCountAfterSecondEnable = shell.invocations.filter {
            $0.arguments.first?.hasPrefix("-get") == true
        }.count
        XCTAssertEqual(getCountAfterFirstEnable, getCountAfterSecondEnable)

        // disable() restores the original pre-linko state.
        try manager.disable()
        XCTAssertTrue(shell.invocations.contains {
            $0.arguments == ["-setwebproxy", "Wi-Fi", "old-proxy.example.com", "8080"]
        })
    }

    func testDisableRestoresRemainingServicesWhenOneFails() throws {
        let shell = makeShell()
        let manager = makeManager(shell: shell)
        try manager.enable(host: "127.0.0.1", port: 7890)

        // First restore command fails; the others must still run.
        shell.responses["-setwebproxystate Wi-Fi"] = ShellResult(
            exitCode: 9, standardOutput: "", standardError: "nope"
        )
        XCTAssertThrowsError(try manager.disable())
        XCTAssertFalse(manager.isEnabled, "state must not desync after a partial restore")
        XCTAssertTrue(shell.invocations.contains {
            $0.arguments == ["-setwebproxystate", "Thunderbolt Bridge", "off"]
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotFileURL.path))
    }
}
