import XCTest
@testable import LinkoKit

/// Pins `ConfigValidator.parse` against real `sing-box check` stderr samples
/// (sing-box 1.13.13) plus the level/ANSI edge cases. All offline: no binary
/// is ever spawned. Lines are reproduced verbatim including the `\u{1B}[31m…`
/// colorization sing-box emits even when stderr is redirected to a file.
final class ConfigValidatorTests: XCTestCase {
    private let esc = "\u{1B}"

    // MARK: - Real sing-box check samples

    func testInvalidJSONIsFatalError() {
        let stderr = "\(esc)[31mFATAL\(esc)[0m[0000] decode config at /tmp/bad.json: invalid character 't' looking for beginning of object key string: row 1, column 3"
        let result = ConfigValidator.parse(exitCode: 1, standardError: stderr, standardOutput: "")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(
            result.errors.first,
            "decode config at /tmp/bad.json: invalid character 't' looking for beginning of object key string: row 1, column 3"
        )
        // The time prefix and ANSI codes must be gone.
        XCTAssertFalse(result.errorSummary.contains("[0000]"))
        XCTAssertFalse(result.errorSummary.contains(esc))
    }

    func testUnknownOutboundMethodIsFatalError() {
        let stderr = "\(esc)[31mFATAL\(esc)[0m[0000] initialize outbound[0]: unknown method: "
        let result = ConfigValidator.parse(exitCode: 1, standardError: stderr, standardOutput: "")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors, ["initialize outbound[0]: unknown method:"])
    }

    func testInvalidRealityPublicKeyIsFatalError() {
        let stderr = "\(esc)[31mFATAL\(esc)[0m[0000] initialize outbound[0]: invalid public_key"
        let result = ConfigValidator.parse(exitCode: 1, standardError: stderr, standardOutput: "")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors, ["initialize outbound[0]: invalid public_key"])
    }

    func testLegacyDeprecationReportedAsFatalIsError() {
        // In sing-box 1.13 a removed legacy field surfaces as FATAL on `check`.
        let stderr = "\(esc)[31mFATAL\(esc)[0m[0000] decode config at /tmp/c.json: inbounds[0]: legacy inbound fields are deprecated in sing-box 1.11.0 and removed in sing-box 1.13.0"
        let result = ConfigValidator.parse(exitCode: 1, standardError: stderr, standardOutput: "")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors.first?.contains("legacy inbound fields") == true)
    }

    func testLegacyDNSEmitsErrorAndFatalBothAsErrors() {
        // Verbatim sing-box 1.13.13 output for the legacy DNS server format —
        // the exact failure class this round hardens. The checker prints an
        // ERROR deprecation notice AND a FATAL "set env var" line; both must
        // be surfaced as errors so a legacy-DNS config never silently starts.
        let stderr = """
        \(esc)[31mERROR\(esc)[0m[0000] legacy DNS servers is deprecated in sing-box 1.12.0 and will be removed in sing-box 1.14.0, checkout documentation for migration: https://sing-box.sagernet.org/migration/#migrate-to-new-dns-server-formats
        \(esc)[31mFATAL\(esc)[0m[0000] to continuing using this feature, set environment variable ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
        """
        let result = ConfigValidator.parse(exitCode: 1, standardError: stderr, standardOutput: "")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.errors.count, 2)
        XCTAssertTrue(result.errors[0].contains("legacy DNS servers is deprecated"))
        XCTAssertTrue(result.errors[1].contains("ENABLE_DEPRECATED_LEGACY_DNS_SERVERS"))
        XCTAssertFalse(result.errorSummary.contains("[0000]"))
        XCTAssertFalse(result.errorSummary.contains(esc))
    }

    func testMissingMethodFieldIsErrorWithTrailingColon() {
        // Verbatim sing-box 1.13.13 output for a shadowsocks outbound missing
        // its `method` — a missing-required-field ERROR class. The trailing
        // space after the colon must be trimmed.
        let stderr = "\(esc)[31mFATAL\(esc)[0m[0000] initialize outbound[0]: unknown method: "
        let result = ConfigValidator.parse(exitCode: 1, standardError: stderr, standardOutput: "")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors, ["initialize outbound[0]: unknown method:"])
    }

    func testValidConfigProducesNoErrorsOrWarnings() {
        // `sing-box check` on a good config prints nothing and exits 0.
        let result = ConfigValidator.parse(exitCode: 0, standardError: "", standardOutput: "")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.errorSummary, "")
    }

    // MARK: - WARN vs ERROR classification

    func testWarnIsAWarningNotAnError() {
        // sing-box colorizes WARN in yellow (33).
        let stderr = "\(esc)[33mWARN\(esc)[0m[0000] geoip database is deprecated, use rule-set instead"
        let result = ConfigValidator.parse(exitCode: 0, standardError: stderr, standardOutput: "")
        XCTAssertTrue(result.isValid, "a deprecation WARN must not block startup")
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.warnings, ["geoip database is deprecated, use rule-set instead"])
    }

    func testErrorLevelIsAnError() {
        let stderr = "\(esc)[31mERROR\(esc)[0m[0000] something went wrong"
        let result = ConfigValidator.parse(exitCode: 1, standardError: stderr, standardOutput: "")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors, ["something went wrong"])
    }

    func testInfoAndDebugLinesAreIgnored() {
        let stderr = """
        \(esc)[34mINFO\(esc)[0m[0000] sing-box started
        \(esc)[37mDEBUG\(esc)[0m[0000] loaded 12 rules
        TRACE[0000] inbound bound
        """
        let result = ConfigValidator.parse(exitCode: 0, standardError: stderr, standardOutput: "")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.warnings, [])
    }

    func testMixedWarnAndErrorAreSeparated() {
        let stderr = """
        \(esc)[33mWARN\(esc)[0m[0000] field X is deprecated
        \(esc)[31mERROR\(esc)[0m[0000] outbound Y is invalid
        \(esc)[33mWARN\(esc)[0m[0000] field Z is deprecated
        """
        let result = ConfigValidator.parse(exitCode: 1, standardError: stderr, standardOutput: "")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors, ["outbound Y is invalid"])
        XCTAssertEqual(result.warnings, ["field X is deprecated", "field Z is deprecated"])
    }

    // MARK: - Robustness

    func testPlainUncolorizedLinesParse() {
        // Defensive: should a future sing-box drop colorization, levels still
        // classify from the leading token.
        let stderr = "FATAL[0000] initialize outbound[0]: invalid public_key"
        let result = ConfigValidator.parse(exitCode: 1, standardError: stderr, standardOutput: "")
        XCTAssertEqual(result.errors, ["initialize outbound[0]: invalid public_key"])
    }

    func testLevelTokenWithoutTimePrefixParses() {
        let stderr = "\(esc)[31mFATAL\(esc)[0m something happened"
        let result = ConfigValidator.parse(exitCode: 1, standardError: stderr, standardOutput: "")
        XCTAssertEqual(result.errors, ["something happened"])
    }

    func testNonZeroExitWithNoClassifiableOutputStillFails() {
        // A non-zero exit must never read as valid even if we can't parse a
        // level line — otherwise a silent checker failure would start a bad core.
        let result = ConfigValidator.parse(exitCode: 1, standardError: "weird untagged output", standardOutput: "")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors, ["weird untagged output"])
    }

    func testNonZeroExitWithEmptyOutputGetsGenericError() {
        let result = ConfigValidator.parse(exitCode: 2, standardError: "", standardOutput: "")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors.first?.contains("退出码 2") == true)
    }

    func testFallsBackToStdoutWhenStderrEmpty() {
        let stdout = "\(esc)[31mFATAL\(esc)[0m[0000] from stdout"
        let result = ConfigValidator.parse(exitCode: 1, standardError: "", standardOutput: stdout)
        XCTAssertEqual(result.errors, ["from stdout"])
    }

    func testZeroExitWithOnlyWarningsIsValid() {
        let stderr = "\(esc)[33mWARN\(esc)[0m[0000] using a deprecated default"
        let result = ConfigValidator.parse(exitCode: 0, standardError: stderr, standardOutput: "")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.warnings, ["using a deprecated default"])
    }

    // MARK: - End-to-end via injected shell

    func testValidateShellsOutWithCheckArguments() {
        let shell = RecordingShell(result: ShellResult(exitCode: 0, standardOutput: "", standardError: ""))
        let validator = ConfigValidator(shell: shell)
        let config = URL(fileURLWithPath: "/tmp/config.json")
        let binary = URL(fileURLWithPath: "/opt/sing-box")

        let result = validator.validate(configFileURL: config, binaryURL: binary)

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(shell.lastExecutablePath, "/opt/sing-box")
        XCTAssertEqual(shell.lastArguments, ["check", "-c", "/tmp/config.json"])
    }

    func testValidateReportsLaunchFailureAsError() {
        struct LaunchError: Error {}
        let shell = ThrowingShell(error: LaunchError())
        let validator = ConfigValidator(shell: shell)

        let result = validator.validate(
            configFileURL: URL(fileURLWithPath: "/tmp/config.json"),
            binaryURL: URL(fileURLWithPath: "/opt/sing-box")
        )
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.count, 1)
    }
}

// MARK: - Test doubles

private final class RecordingShell: ShellRunning, @unchecked Sendable {
    private let result: ShellResult
    private(set) var lastExecutablePath: String?
    private(set) var lastArguments: [String]?

    init(result: ShellResult) { self.result = result }

    func run(executablePath: String, arguments: [String]) throws -> ShellResult {
        lastExecutablePath = executablePath
        lastArguments = arguments
        return result
    }
}

private struct ThrowingShell: ShellRunning {
    let error: Error
    func run(executablePath: String, arguments: [String]) throws -> ShellResult {
        throw error
    }
}
