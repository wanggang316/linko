import Foundation

/// Pre-flight config validator: shells out to `sing-box check -c <file>` and
/// parses the level-tagged stderr into a typed result. This is linko's
/// flagship safety feature — `AppState` calls it before every core start so a
/// bad node, rule, or DNS block can never silently break the user's network.
///
/// The `ShellRunning` seam is injected so the start path can be exercised with
/// canned process output; the *parser* (`Self.parse`) is pure and is what the
/// unit tests pin against real sing-box `check` stderr samples.
public struct ConfigValidator: ConfigValidating {
    private let shell: ShellRunning

    public init(shell: ShellRunning = ProcessShellRunner()) {
        self.shell = shell
    }

    public func validate(configFileURL: URL, binaryURL: URL) -> ConfigValidationResult {
        let result: ShellResult
        do {
            result = try shell.run(
                executablePath: binaryURL.path,
                arguments: ["check", "-c", configFileURL.path]
            )
        } catch {
            // Could not even launch the checker. Treat as a hard error so the
            // caller has one decision point and never starts on uncertainty.
            return ConfigValidationResult(
                isValid: false,
                errors: ["无法运行配置检查（\(binaryURL.lastPathComponent)）：\(error.localizedDescription)"],
                warnings: []
            )
        }
        return Self.parse(
            exitCode: result.exitCode,
            standardError: result.standardError,
            standardOutput: result.standardOutput
        )
    }

    // MARK: - Pure parser (unit-tested offline)

    /// Severity levels emitted by sing-box's logger, highest first.
    private enum Level: String {
        case fatal = "FATAL"
        case error = "ERROR"
        case warn = "WARN"
        case info = "INFO"
        case debug = "DEBUG"
        case trace = "TRACE"
    }

    /// Parses the output of `sing-box check`. FATAL/ERROR lines become
    /// `errors`, WARN lines become `warnings`; INFO/DEBUG/TRACE are ignored.
    /// Deprecation WARNs are warnings, never errors.
    ///
    /// sing-box colorizes its log lines even when stderr is not a TTY, so the
    /// raw form of a line is:
    ///   "\u{1B}[31mFATAL\u{1B}[0m[0000] decode config at …: …"
    /// We strip ANSI escapes first, then read the leading level token. A
    /// non-zero exit with no recognizable level line still yields one generic
    /// error so a silent failure can never pass as success.
    public static func parse(
        exitCode: Int32,
        standardError: String,
        standardOutput: String
    ) -> ConfigValidationResult {
        var errors: [String] = []
        var warnings: [String] = []

        // sing-box writes diagnostics to stderr; fall back to stdout in case a
        // future version moves them.
        let combined = standardError.isEmpty ? standardOutput : standardError
        for rawLine in combined.split(whereSeparator: \.isNewline) {
            let line = stripANSI(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let (level, message) = splitLevel(from: line) else { continue }
            switch level {
            case .fatal, .error:
                errors.append(message)
            case .warn:
                warnings.append(message)
            case .info, .debug, .trace:
                continue
            }
        }

        // A non-zero exit must never be reported as valid. If the checker
        // failed but emitted nothing we could classify, surface a generic
        // error rather than letting an empty `errors` read as success.
        if exitCode != 0 && errors.isEmpty {
            let fallback = stripANSI(combined).trimmingCharacters(in: .whitespacesAndNewlines)
            errors.append(fallback.isEmpty ? "配置检查失败（退出码 \(exitCode)）。" : fallback)
        }

        return ConfigValidationResult(
            isValid: errors.isEmpty,
            errors: errors,
            warnings: warnings
        )
    }

    /// Splits a level-tagged line into its level and the human-readable
    /// message, dropping the `[0000]` time prefix sing-box inserts. Returns
    /// `nil` when the line does not begin with a known level token.
    private static func splitLevel(from line: String) -> (Level, String)? {
        // A level token is a leading run of uppercase letters terminated by a
        // non-letter (the time bracket "[", or whitespace).
        let letters = line.prefix { $0.isLetter }
        guard let level = Level(rawValue: String(letters)) else { return nil }
        var rest = Substring(line.dropFirst(letters.count))
        // Drop an optional "[0000]" (or "[00000]") time prefix.
        if rest.first == "[", let close = rest.firstIndex(of: "]") {
            rest = rest[rest.index(after: close)...]
        }
        let message = rest.trimmingCharacters(in: .whitespaces)
        return (level, message.isEmpty ? line : message)
    }

    /// Removes ANSI SGR escape sequences (e.g. "\u{1B}[31m", "\u{1B}[0m").
    private static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        var pending: Character? = nil
        while let char = pending ?? iterator.next() {
            pending = nil
            guard char == "\u{1B}" else {
                output.append(char)
                continue
            }
            // Expect "[", then parameter/intermediate bytes, then a final byte
            // in the range @-~ (0x40–0x7E). Consume through the final byte.
            guard let next = iterator.next() else { break }
            if next != "[" {
                // Not a CSI sequence; keep both characters verbatim.
                output.append(char)
                pending = next
                continue
            }
            while let seqChar = iterator.next() {
                if ("\u{40}"..."\u{7E}").contains(seqChar) { break }
            }
        }
        return output
    }
}
