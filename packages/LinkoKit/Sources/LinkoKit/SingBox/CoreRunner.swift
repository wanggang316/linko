import Foundation

/// Errors thrown while managing the sing-box subprocess.
public enum CoreRunnerError: Error, Equatable, LocalizedError {
    case alreadyRunning
    case binaryNotExecutable(path: String)
    case launchFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "The sing-box core is already running."
        case let .binaryNotExecutable(path):
            return "No executable sing-box binary at \(path)."
        case let .launchFailed(reason):
            return "Failed to launch sing-box: \(reason)"
        }
    }
}

/// Manages the sing-box core subprocess: launches `sing-box run -c <config>`,
/// redirects its output to a log file, and terminates it cleanly on `stop()`.
public final class CoreRunner: CoreRunning, @unchecked Sendable {
    /// How long `stop()` waits for a graceful SIGTERM exit before SIGKILL.
    private static let gracefulStopTimeout: TimeInterval = 2.0

    private let lock = NSLock()
    private var process: Process?
    private var logHandle: FileHandle?
    private var stateStorage: CoreState = .stopped
    private var stateChangeHandler: (@Sendable (CoreState) -> Void)?

    /// Invoked (on an arbitrary queue) whenever the observable state changes.
    /// Guarded by the lock: it is written from the main thread and read from
    /// the termination-handler thread.
    public var onStateChange: (@Sendable (CoreState) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stateChangeHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stateChangeHandler = newValue
        }
    }

    public init() {}

    deinit {
        stop()
    }

    public var state: CoreState {
        lock.lock()
        defer { lock.unlock() }
        return stateStorage
    }

    public var isRunning: Bool {
        if case .running = state {
            return true
        }
        return false
    }

    public func start(binaryURL: URL, configFileURL: URL, logFileURL: URL) throws {
        // The whole check-launch-assign transition happens under one critical
        // section so two concurrent `start()` calls can never both launch a
        // child (the loser sees `.running` and throws).
        lock.lock()

        if case .running = stateStorage {
            lock.unlock()
            throw CoreRunnerError.alreadyRunning
        }

        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            lock.unlock()
            throw CoreRunnerError.binaryNotExecutable(path: binaryURL.path)
        }

        let handle: FileHandle
        do {
            handle = try openLogFile(at: logFileURL)
        } catch {
            lock.unlock()
            throw error
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["run", "-c", configFileURL.path]
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] finished in
            self?.handleTermination(of: finished)
        }

        do {
            try process.run()
        } catch {
            try? handle.close()
            lock.unlock()
            throw CoreRunnerError.launchFailed(reason: error.localizedDescription)
        }

        self.process = process
        self.logHandle = handle
        let newState = CoreState.running(pid: process.processIdentifier)
        stateStorage = newState
        let handler = stateChangeHandler
        lock.unlock()
        handler?(newState)
    }

    public func stop() {
        // Transition the observable state synchronously so an immediate
        // `start()` after `stop()` never races the termination handler.
        lock.lock()
        guard let process = self.process else {
            lock.unlock()
            return
        }
        self.process = nil
        let handle = logHandle
        logHandle = nil
        stateStorage = .stopped
        let handler = stateChangeHandler
        lock.unlock()

        if process.isRunning {
            process.terminate()
            // Bounded graceful wait, then SIGKILL so a hung core can never
            // wedge the caller (stop() runs on the main actor).
            let deadline = Date().addingTimeInterval(Self.gracefulStopTimeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // SIGKILL cannot be caught or ignored, so this returns promptly.
            process.waitUntilExit()
        }
        try? handle?.close()
        handler?(.stopped)
        // The (late) termination handler sees self.process !== process and
        // bails out without touching state.
    }

    // MARK: - Private

    /// Handles a child exit that `stop()` did not claim: an unexpected death.
    private func handleTermination(of process: Process) {
        lock.lock()
        guard self.process === process else {
            lock.unlock()
            return
        }
        let status = process.terminationStatus
        try? logHandle?.close()
        logHandle = nil
        self.process = nil

        let newState = CoreState.failed(
            reason: "sing-box exited unexpectedly (status \(status)). Check the log file for details."
        )
        stateStorage = newState
        let handler = stateChangeHandler
        lock.unlock()
        handler?(newState)
    }

    private func openLogFile(at url: URL) throws -> FileHandle {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
