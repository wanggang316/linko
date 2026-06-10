import Foundation

// MARK: - Core lifecycle

/// Observable state of the sing-box core subprocess.
public enum CoreState: Equatable, Sendable {
    case stopped
    case running(pid: Int32)
    /// The core exited unexpectedly or failed to launch; the associated value
    /// is a human-readable reason suitable for surfacing in the UI.
    case failed(reason: String)
}

/// Manages the sing-box core subprocess lifecycle.
///
/// Implemented by `CoreRunner` (Sources/LinkoKit/SingBox/), which launches
/// `sing-box run -c <configFileURL>` via Foundation `Process`, redirects
/// stdout/stderr to `logFileURL`, and terminates the child cleanly on `stop()`.
public protocol CoreRunning: AnyObject {
    var state: CoreState { get }
    var isRunning: Bool { get }

    /// Invoked (on an arbitrary queue) whenever the observable state changes,
    /// most importantly when the core exits unexpectedly (`.failed`).
    var onStateChange: (@Sendable (CoreState) -> Void)? { get set }

    /// Launches the core. Throws if the binary is missing/not executable or
    /// if a core is already running.
    func start(binaryURL: URL, configFileURL: URL, logFileURL: URL) throws

    /// Terminates the core if running; safe to call when already stopped.
    /// The state transition to `.stopped` is synchronous: a new `start(...)`
    /// may follow immediately.
    func stop()
}

// MARK: - Shell execution (injectable for tests)

/// Result of running an external process to completion.
public struct ShellResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Runs an external executable to completion. Injected into
/// `SystemProxyManager` so unit tests never spawn real processes.
public protocol ShellRunning: Sendable {
    @discardableResult
    func run(executablePath: String, arguments: [String]) throws -> ShellResult
}

// MARK: - System proxy

/// Toggles the macOS system proxy (web, secure web, SOCKS) on all enabled
/// network services via `/usr/sbin/networksetup`.
///
/// Implemented by `SystemProxyManager` (Sources/LinkoKit/System/). `disable()`
/// must restore the proxy state captured at the preceding `enable(...)`.
public protocol SystemProxyRunning: AnyObject {
    var isEnabled: Bool { get }

    /// Points web/secure-web/SOCKS proxies of every enabled network service
    /// at `host:port`, remembering the previous state for restoration.
    func enable(host: String, port: Int) throws

    /// Restores the proxy state captured by the last `enable(...)`.
    func disable() throws

    /// Restores proxy settings persisted by a previous session that ended
    /// without `disable()` (crash, force quit, power loss). Returns `true`
    /// if a leftover snapshot was found and restored.
    @discardableResult
    func restorePersistedSnapshotIfPresent() throws -> Bool
}

// MARK: - Clash API

/// A single proxy entry as reported by `GET /proxies`.
public struct ClashProxy: Codable, Equatable, Sendable {
    public let name: String
    public let type: String
    /// Currently selected member, present on selector-type proxies.
    public let now: String?
    /// Member tags, present on selector/group-type proxies.
    public let all: [String]?

    public init(name: String, type: String, now: String? = nil, all: [String]? = nil) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
    }
}

/// Client for the sing-box Clash-compatible API (`experimental.clash_api`).
///
/// Implemented by `ClashAPIClient` (Sources/LinkoKit/ClashAPI/) on URLSession.
public protocol ClashAPIProviding: Sendable {
    /// `GET /version` -> the reported core version string.
    func version() async throws -> String

    /// `GET /proxies` -> all proxies keyed by tag.
    func proxies() async throws -> [String: ClashProxy]

    /// `PUT /proxies/{selector}` with body `{"name": nodeName}`.
    func select(selector: String, nodeName: String) async throws

    /// `GET /proxies/{nodeName}/delay?timeout=<ms>&url=<testURL>` -> delay in ms.
    func delay(nodeName: String, testURL: String, timeoutMilliseconds: Int) async throws -> Int

    // MARK: Observability (dashboard)

    /// `GET /connections` -> a single snapshot of all live connections plus
    /// cumulative byte counters. Use for one-shot reads; prefer
    /// `connectionsStream()` for a live view.
    func connectionsSnapshot() async throws -> ClashConnectionsSnapshot

    /// WebSocket `/connections` -> a snapshot pushed roughly once per second.
    /// The stream finishes when the socket closes; cancelling the consuming
    /// task tears the socket down. Frames that fail to decode are skipped.
    func connectionsStream() -> AsyncThrowingStream<ClashConnectionsSnapshot, Error>

    /// WebSocket `/traffic` -> per-second `{up, down}` byte deltas.
    func trafficStream() -> AsyncThrowingStream<ClashTrafficTick, Error>

    /// WebSocket `/logs?level=<level>` -> `{type, payload}` log lines.
    func logsStream(level: ClashLogLevel) -> AsyncThrowingStream<ClashLogEntry, Error>

    /// `DELETE /connections/{id}`, or `DELETE /connections` when `id` is `nil`
    /// (closes every live connection).
    func closeConnection(id: String?) async throws
}

// MARK: - sing-box config generation

/// Builds a complete sing-box 1.x JSON configuration:
/// mixed inbound on 127.0.0.1:<mixedPort>, one outbound per node, a selector
/// outbound tagged "proxy" (all node tags + "direct"), a direct outbound,
/// `route.final = "proxy"`, and `experimental.clash_api` on
/// 127.0.0.1:<clashAPIPort>.
///
/// Implemented by `SingBoxConfigBuilder` (Sources/LinkoKit/SingBox/).
public protocol SingBoxConfigBuilding {
    /// Returns UTF-8 encoded JSON. Throws if `nodes` is empty or a node
    /// cannot be represented in the sing-box schema.
    func build(nodes: [ProxyNode], preferences: AppPreferences) throws -> Data

    /// Returns the outbound tag `build` assigns to each node, positionally
    /// aligned with `nodes`. Display names may collide (the builder dedupes
    /// them), so every Clash API call must address nodes by this tag, never
    /// by the raw display name.
    func outboundTags(for nodes: [ProxyNode]) -> [String]
}

// MARK: - Subscription parsing

/// Outcome of parsing a subscription document: usable nodes plus warnings for
/// entries that were skipped (unknown type, missing required fields).
public struct SubscriptionParseResult: Equatable, Sendable {
    public let nodes: [ProxyNode]
    public let warnings: [String]

    public init(nodes: [ProxyNode], warnings: [String] = []) {
        self.nodes = nodes
        self.warnings = warnings
    }
}

/// Parses Clash YAML subscription documents into `ProxyNode`s.
///
/// Implemented by `SubscriptionParser` (Sources/LinkoKit/Subscription/) using
/// Yams. Malformed or unsupported entries are skipped with a warning, never a
/// crash; a throw is reserved for documents that are not valid Clash YAML at all.
public protocol SubscriptionParsing {
    func parse(clashYAML: String) throws -> SubscriptionParseResult
}
