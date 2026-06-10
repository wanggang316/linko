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

// MARK: - Pre-flight config validation

/// Outcome of running `sing-box check` against a generated configuration.
///
/// `errors` are FATAL/ERROR lines that mean the core would refuse to start
/// (a bad node, an unrepresentable rule, an invalid Reality public_key, …).
/// `warnings` are WARN lines (typically deprecation notices) that do not
/// prevent a start. A config is `isValid` exactly when there are no errors.
public struct ConfigValidationResult: Equatable, Sendable {
    public let isValid: Bool
    public let errors: [String]
    public let warnings: [String]

    public init(isValid: Bool, errors: [String], warnings: [String]) {
        self.isValid = isValid
        self.errors = errors
        self.warnings = warnings
    }

    /// A single line summarizing the errors, for surfacing in the UI.
    public var errorSummary: String {
        errors.joined(separator: "\n")
    }
}

/// Pre-flight validates a generated sing-box config before the core is started
/// or restarted: a bad node or rule must never silently break the user's
/// network. Implemented by `ConfigValidator` (Sources/LinkoKit/Validation/),
/// which shells out to `<binary> check -c <file>` via the injected
/// `ShellRunning` seam and parses the level-tagged stderr.
public protocol ConfigValidating: Sendable {
    /// Runs `<binaryURL> check -c <configFileURL>` and parses the result.
    /// Never throws: a failure to even launch the checker is reported as an
    /// error in the returned result so the caller has a single decision point.
    func validate(configFileURL: URL, binaryURL: URL) -> ConfigValidationResult
}

// MARK: - Launch at login

/// Status of the app's "launch at login" registration, mirroring the relevant
/// cases of `SMAppService.Status`.
public enum LoginItemStatus: Equatable, Sendable {
    /// Not registered to launch at login.
    case notRegistered
    /// Registered and enabled.
    case enabled
    /// Registered but the user must approve it in System Settings > General >
    /// Login Items before it takes effect.
    case requiresApproval
    /// The service is not found / unavailable in this build configuration.
    case notFound
}

/// Controls the app's "launch at login" registration. Implemented app-side by
/// an `SMAppService.mainApp` wrapper (declared here so LinkoKit consumers and
/// `AppState` can depend on the protocol, not the concrete service).
public protocol LoginItemControlling: Sendable {
    /// The current registration status.
    var status: LoginItemStatus { get }

    /// Registers the main app to launch at login. Throws if registration
    /// fails (the caller surfaces the message and leaves the toggle off).
    func register() throws

    /// Unregisters the main app from launching at login. Safe to call when
    /// not registered.
    func unregister() throws
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

/// Builds a complete sing-box 1.x JSON configuration.
///
/// Baseline shape (empty `preferences.routing`): mixed inbound on
/// 127.0.0.1:<mixedPort>, one outbound per node, a selector outbound tagged
/// "proxy" (all node tags + "direct"), a direct outbound, `route.final =
/// "proxy"`, and `experimental.clash_api` on 127.0.0.1:<clashAPIPort>.
///
/// When `preferences.routing` is populated the builder additionally emits:
/// - one group outbound per `PolicyGroup` (selector / urltest), resolving
///   member tags (nodes, nested groups, built-ins) and degrading
///   fallback/load-balance to urltest;
/// - `route.rules` from the enabled `RoutingRule`s (logical rules nested),
///   each routed to its `target` outbound via `{action:"route", outbound:tag}`;
/// - `route.rule_set` from referenced `RuleSetEntry`s;
/// - `route.final` from `routing.finalTarget`;
/// - a `dns` block when `routing.dns.isEnabled`.
///
/// Implemented by `SingBoxConfigBuilder` (Sources/LinkoKit/SingBox/).
public protocol SingBoxConfigBuilding {
    /// Returns UTF-8 encoded JSON. Throws if `nodes` is empty or a node/rule/
    /// group cannot be represented in the sing-box schema.
    func build(nodes: [ProxyNode], preferences: AppPreferences) throws -> Data

    /// Returns the outbound tag `build` assigns to each node, positionally
    /// aligned with `nodes`. Display names may collide (the builder dedupes
    /// them), so every Clash API call must address nodes by this tag, never
    /// by the raw display name.
    func outboundTags(for nodes: [ProxyNode]) -> [String]

    /// Validates that `preferences.routing` is internally consistent against
    /// the given nodes (every rule/group/DNS target resolves to a known node
    /// tag, group, or built-in; no group cycles; rule-set references exist).
    /// Returns human-readable warnings for soft problems (unresolved targets
    /// are dropped, degraded group types) without throwing. Hard errors that
    /// would prevent `build` from succeeding are thrown instead.
    func validate(nodes: [ProxyNode], routing: RoutingConfig) throws -> [String]
}

// MARK: - Rule import (Surge / Clash migration)

/// Outcome of importing a `[Rule]`/`rules:` section: the parsed rules plus
/// per-line warnings for entries that were skipped or only partially mapped.
public struct RuleImportResult: Equatable, Sendable {
    public let rules: [RoutingRule]
    /// Policy names referenced by the imported rules, in first-seen order.
    /// The caller maps these to existing group/node tags (by name) and warns
    /// on any that do not resolve.
    public let referencedPolicies: [String]
    public let warnings: [String]

    public init(rules: [RoutingRule], referencedPolicies: [String] = [], warnings: [String] = []) {
        self.rules = rules
        self.referencedPolicies = referencedPolicies
        self.warnings = warnings
    }
}

/// Parses an existing Surge profile `[Rule]` section or a Clash `rules:` list
/// into `RoutingRule`s on a best-effort basis. Unsupported rule kinds are
/// skipped with a warning rather than throwing.
///
/// Implemented by `RuleImporter` (Sources/LinkoKit/Routing/).
public protocol RuleImporting {
    /// Parses the lines of a Surge `[Rule]` section (e.g.
    /// "DOMAIN-SUFFIX,google.com,Proxy"). Targets become rule `target`s by name.
    func importSurgeRules(_ text: String) -> RuleImportResult

    /// Parses a Clash YAML `rules:` list (e.g.
    /// "- DOMAIN-SUFFIX,google.com,Proxy"), accepting either the full document
    /// or just the rule lines.
    func importClashRules(_ text: String) -> RuleImportResult
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

// MARK: - Multi-profile management

/// A lightweight, value-type summary of a profile for list rendering: the menu
/// and management UI bind to `[ProfileSummary]` rather than the full `Profile`
/// (which carries every node), so a profile list redraw never copies node data.
public struct ProfileSummary: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    /// Whether this is the currently active profile.
    public let isActive: Bool
    /// Number of subscriptions in the profile.
    public let subscriptionCount: Int
    /// Number of nodes across all of the profile's subscriptions.
    public let nodeCount: Int
    /// The profile's proxy mode (for an at-a-glance badge).
    public let proxyMode: ProxyMode
    public let updatedAt: Date

    public init(
        id: UUID,
        name: String,
        isActive: Bool,
        subscriptionCount: Int,
        nodeCount: Int,
        proxyMode: ProxyMode,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.subscriptionCount = subscriptionCount
        self.nodeCount = nodeCount
        self.proxyMode = proxyMode
        self.updatedAt = updatedAt
    }

    /// Derives a summary from a `Profile`, given the active id.
    public init(profile: Profile, activeProfileID: UUID) {
        self.init(
            id: profile.id,
            name: profile.name,
            isActive: profile.id == activeProfileID,
            subscriptionCount: profile.subscriptions.count,
            nodeCount: profile.allNodes.count,
            proxyMode: profile.preferences.proxyMode,
            updatedAt: profile.updatedAt
        )
    }
}

/// The public profile-management surface implemented by the app's `AppState`
/// (declared here so LinkoKit-side consumers and tests can depend on the
/// contract, and to document the exact signatures downstream UI codes against).
///
/// Every mutating call persists the profile collection. Switching the active
/// profile (`switchProfile`) is the one operation that touches the running
/// core: it swaps in the target profile's `subscriptions` + `preferences`,
/// re-generates and pre-flight-validates the config, and restarts the core if
/// it was running — all on `AppState`'s serialized lifecycle chain. Validation
/// failure aborts the switch and surfaces the error, leaving the previously
/// active profile in place. `@MainActor` because `AppState` is main-actor-bound.
@MainActor
public protocol ProfileManaging: AnyObject {
    /// Value-type summaries of all profiles, in stored order, for list UIs.
    var profileSummaries: [ProfileSummary] { get }
    /// The id of the active profile (drives selection highlighting).
    var activeProfileID: UUID { get }

    /// Creates a new empty profile named `name` (de-duplicated) and switches to
    /// it. Returns the new profile's id.
    @discardableResult
    func createProfile(named name: String) async -> UUID

    /// Deep-duplicates the profile with `id` (fresh node ids, re-pointed
    /// selection) and switches to the copy. Returns the copy's id, or `nil` if
    /// `id` is unknown.
    @discardableResult
    func duplicateProfile(id: UUID) async -> UUID?

    /// Renames the profile with `id`. Does not touch the running core.
    func renameProfile(id: UUID, to name: String)

    /// Deletes the profile with `id`. When it was active, activation moves to a
    /// neighbor and the core is restarted onto that profile. Surfaces an error
    /// (and is a no-op) when `id` is the last remaining profile.
    func deleteProfile(id: UUID) async

    /// Switches the active profile to `id`: swaps in its subscriptions +
    /// preferences, re-generates + validates the config, and restarts the core
    /// if running. A no-op when `id` is already active. On validation failure
    /// the switch is aborted and the error surfaced.
    func switchProfile(id: UUID) async
}
