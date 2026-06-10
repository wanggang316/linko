import Foundation

/// `ShellRunning` implementation backed by Foundation `Process`.
public struct ProcessShellRunner: ShellRunning {
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

        // Drain stdout and stderr concurrently: reading them sequentially can
        // deadlock when the child fills the second pipe's buffer (~64KB) while
        // we're still blocked reading the first.
        let stderrQueue = DispatchQueue(label: "linko.shell.stderr")
        let stderrBox = DataBox()
        stderrQueue.async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stderrQueue.sync {} // wait for the stderr read to finish
        let stderrData = stderrBox.data
        process.waitUntilExit()

        return ShellResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

/// Box that lets the stderr-draining queue hand its result back to the caller
/// after a `sync` barrier (the write happens-before the barrier returns).
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
