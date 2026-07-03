import Foundation

/// Failure thrown by `ProcessShellRunner` itself, as opposed to a nonzero
/// exit of the child (which is reported through `ShellResult.exitCode`).
public enum ProcessShellRunnerError: Error, Equatable {
    /// stdout or stderr grew past `ProcessShellRunner.outputByteLimit`. The
    /// child was killed and its buffered output discarded: every legitimate
    /// caller (networksetup, osascript printing a page URL, `sing-box check`)
    /// emits output orders of magnitude below the cap, so breaching it means
    /// the process is misbehaving — or is not the binary we think it is —
    /// and nothing it wrote is worth keeping.
    case outputLimitExceeded(limitBytes: Int)
}

/// `ShellRunning` implementation backed by Foundation `Process`.
public struct ProcessShellRunner: ShellRunning {
    /// Upper bound (per stream) on how much child output `run` buffers.
    /// Far above anything the real consumers produce, small enough that a
    /// hostile or runaway child can never grow an unbounded buffer here.
    static let outputByteLimit = 4 * 1024 * 1024

    public init() {}

    @discardableResult
    public func run(executablePath: String, arguments: [String]) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // A drain that hits the cap must kill the child, not merely stop
        // reading: a stopped reader leaves the child blocked on its full
        // pipe, deadlocking the other stream's drain (and `waitUntilExit`)
        // forever. SIGKILL rather than SIGTERM — the cap exists to contain
        // misbehaving or impersonated binaries, which may ignore a SIGTERM.
        let pid = process.processIdentifier
        let killChild: @Sendable () -> Void = { kill(pid, SIGKILL) }

        // Drain stdout and stderr concurrently: reading them sequentially can
        // deadlock when the child fills the second pipe's buffer (~64KB) while
        // we're still blocked reading the first.
        let stderrQueue = DispatchQueue(label: "linko.shell.stderr")
        let stderrBox = DrainBox()
        stderrQueue.async {
            stderrBox.outcome = Self.drain(
                stderrPipe.fileHandleForReading,
                limit: Self.outputByteLimit,
                onLimitBreach: killChild
            )
        }
        let stdoutOutcome = Self.drain(
            stdoutPipe.fileHandleForReading,
            limit: Self.outputByteLimit,
            onLimitBreach: killChild
        )
        stderrQueue.sync {} // wait for the stderr drain to finish
        let stderrOutcome = stderrBox.outcome
        process.waitUntilExit()

        guard !stdoutOutcome.breachedLimit, !stderrOutcome.breachedLimit else {
            throw ProcessShellRunnerError.outputLimitExceeded(limitBytes: Self.outputByteLimit)
        }

        return ShellResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: stdoutOutcome.data, encoding: .utf8) ?? "",
            standardError: String(data: stderrOutcome.data, encoding: .utf8) ?? ""
        )
    }

    /// Reads `handle` to EOF, keeping at most `limit` bytes. The first byte
    /// past the limit fires `onLimitBreach` — whose job is to make EOF arrive
    /// (`run` kills the child) — drops what was buffered, and discards the
    /// rest of the stream so the drain still terminates deterministically.
    /// Internal for unit tests; `run` is the only production caller.
    static func drain(
        _ handle: FileHandle,
        limit: Int,
        onLimitBreach: () -> Void
    ) -> (data: Data, breachedLimit: Bool) {
        var data = Data()
        var breached = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return (data, breached) } // EOF
            guard !breached else { continue } // discard the remainder
            data.append(chunk)
            if data.count > limit {
                breached = true
                data.removeAll() // hostile bulk: keep none of it
                onLimitBreach()
            }
        }
    }
}

/// Box that lets the stderr-draining queue hand its result back to the caller
/// after a `sync` barrier (the write happens-before the barrier returns).
private final class DrainBox: @unchecked Sendable {
    var outcome: (data: Data, breachedLimit: Bool) = (Data(), false)
}
