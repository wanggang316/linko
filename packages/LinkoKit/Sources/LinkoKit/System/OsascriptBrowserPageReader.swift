import Foundation

/// Reads the URL of the frontmost tab of a supported browser by running
/// `/usr/bin/osascript` through the injected `ShellRunning` seam.
///
/// Two AppleScript dialects cover the supported browsers: Safari exposes the
/// frontmost tab as `current tab`, the Chromium family (Chrome, Edge, Arc,
/// Brave) as `active tab`. Browsers are addressed by bundle id, so localized
/// or renamed app bundles keep working.
///
/// Reads are single-flight per bundle id (process-wide): while one osascript
/// is still running — typically hung behind a pending Automation TCC prompt —
/// further reads of the same browser fail fast with `.timedOut` instead of
/// accumulating blocked osascript processes and worker threads.
public struct OsascriptBrowserPageReader: BrowserPageReading {
    /// The browsers the reader knows how to script, keyed by bundle id.
    private enum SupportedBrowser: String, CaseIterable {
        case safari = "com.apple.Safari"
        case chrome = "com.google.Chrome"
        case edge = "com.microsoft.edgemac"
        case arc = "company.thebrowser.Browser"
        case brave = "com.brave.Browser"

        var displayName: String {
            switch self {
            case .safari: return "Safari"
            case .chrome: return "Google Chrome"
            case .edge: return "Microsoft Edge"
            case .arc: return "Arc"
            case .brave: return "Brave Browser"
            }
        }

        /// AppleScript reading the frontmost tab's URL, in the dialect the
        /// browser's scripting dictionary understands.
        var script: String {
            switch self {
            case .safari:
                return "tell application id \"\(rawValue)\" to get URL of current tab of front window"
            case .chrome, .edge, .arc, .brave:
                return "tell application id \"\(rawValue)\" to get URL of active tab of front window"
            }
        }
    }

    private static let osascriptPath = "/usr/bin/osascript"

    /// Bundle ids of the browsers this reader can script, for callers that
    /// gate UI on browser support without invoking the reader.
    public static var supportedBundleIDs: Set<String> {
        Set(SupportedBrowser.allCases.map(\.rawValue))
    }

    private let shell: ShellRunning
    private let timeout: TimeInterval
    private let inFlight: InFlightRegistry

    /// - Parameter timeout: upper bound on how long a single read may take.
    ///   The 1s default keeps callers (e.g. a menu about to open) snappy. A
    ///   pending Automation TCC consent prompt blocks osascript until the
    ///   user answers, so callers expecting the first-ever prompt must
    ///   coordinate a longer timeout themselves. While such a read is still
    ///   running, further reads of the same browser fail fast with
    ///   `.timedOut` instead of stacking more blocked osascript processes.
    public init(shell: ShellRunning = ProcessShellRunner(), timeout: TimeInterval = 1.0) {
        self.init(shell: shell, timeout: timeout, inFlight: .shared)
    }

    /// Test seam: isolates the in-flight registry so concurrency tests never
    /// leak single-flight state across cases.
    init(shell: ShellRunning, timeout: TimeInterval, inFlight: InFlightRegistry) {
        self.shell = shell
        self.timeout = timeout
        self.inFlight = inFlight
    }

    public func currentPageURL(browserBundleID: String) throws -> String {
        guard let browser = SupportedBrowser(rawValue: browserBundleID) else {
            throw BrowserPageReadError.unsupportedBrowser(bundleID: browserBundleID)
        }

        let result = try run(script: browser.script, browser: browser)
        guard result.exitCode == 0 else {
            throw Self.classifyFailure(
                stderr: result.standardError,
                browserName: browser.displayName
            )
        }

        let url = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        // "missing value" is AppleScript's null: a window exists but has no
        // readable URL (e.g. a brand-new empty tab).
        guard !url.isEmpty, url != "missing value" else {
            throw BrowserPageReadError.emptyOutput(browserName: browser.displayName)
        }
        return url
    }

    // MARK: - Failure classification

    /// Maps a nonzero osascript exit to a typed error. Deliberately keyed on
    /// the stable Apple event error codes rather than the human-readable
    /// wording, and deliberately *not* carrying the raw stderr into the
    /// error: script output can embed the page URL and must never reach a
    /// description or a log line.
    private static func classifyFailure(stderr: String, browserName: String) -> BrowserPageReadError {
        if stderr.contains("-1743") || stderr.contains("-10004") {
            // errAEEventNotPermitted / privilege violation: the user declined
            // (or a management profile blocks) the Automation TCC prompt.
            return .permissionDenied(browserName: browserName)
        }
        if stderr.contains("-1719") {
            // errAEIllegalIndex: `front window` does not exist.
            return .noWindow(browserName: browserName)
        }
        return .scriptFailed(browserName: browserName)
    }

    // MARK: - Single flight

    /// Tracks which browsers currently have an osascript read running, so
    /// concurrent reads of the same browser can fail fast. Shared
    /// process-wide by default: readers are cheap value types created ad
    /// hoc, but the guarded resource — one (possibly TCC-prompt-blocked)
    /// osascript per browser — is per-process.
    final class InFlightRegistry: @unchecked Sendable {
        static let shared = InFlightRegistry()

        private let lock = NSLock()
        private var bundleIDs: Set<String> = []

        /// Claims the slot for `bundleID`; `false` when a read is already
        /// running.
        func begin(_ bundleID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return bundleIDs.insert(bundleID).inserted
        }

        /// Releases the slot for `bundleID`.
        func end(_ bundleID: String) {
            lock.lock()
            defer { lock.unlock() }
            bundleIDs.remove(bundleID)
        }
    }

    // MARK: - Timeout plumbing

    /// Runs osascript on a background queue and gives up after `timeout`.
    ///
    /// `ShellRunning` is synchronous, so a timed-out run keeps blocking its
    /// worker thread until the real osascript exits; that is acceptable for
    /// the short-lived osascript and keeps the injection seam mockable.
    ///
    /// Reads are single-flight per browser: while one osascript for a bundle
    /// id is still running (typically hung behind a pending Automation TCC
    /// prompt), further reads fail fast with `.timedOut` instead of spawning
    /// another blocked process and parking another worker thread. The slot is
    /// released by the worker when the shell call actually returns — not when
    /// the caller times out — so the guard holds for the process's whole life.
    private func run(script: String, browser: SupportedBrowser) throws -> ShellResult {
        let browserName = browser.displayName
        guard inFlight.begin(browser.rawValue) else {
            throw BrowserPageReadError.timedOut(browserName: browserName)
        }

        let box = OutcomeBox()
        let finished = DispatchSemaphore(value: 0)
        let shell = self.shell
        let inFlight = self.inFlight
        let bundleID = browser.rawValue

        DispatchQueue.global(qos: .userInitiated).async {
            box.outcome = Result {
                try shell.run(executablePath: Self.osascriptPath, arguments: ["-e", script])
            }
            inFlight.end(bundleID)
            finished.signal()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            throw BrowserPageReadError.timedOut(browserName: browserName)
        }
        guard let result = try? box.outcome?.get() else {
            // The process could not even be launched; there is no script
            // output to classify.
            throw BrowserPageReadError.scriptFailed(browserName: browserName)
        }
        return result
    }
}

/// Box handing the shell outcome across the semaphore barrier (the write
/// happens-before `signal()`, which happens-before a successful `wait`).
private final class OutcomeBox: @unchecked Sendable {
    var outcome: Result<ShellResult, Error>?
}
