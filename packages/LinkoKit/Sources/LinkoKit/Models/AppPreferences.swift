import Foundation

/// User-configurable application preferences, persisted as JSON under
/// `~/Library/Application Support/linko/`.
public struct AppPreferences: Codable, Equatable, Hashable, Sendable {
    /// Valid TCP port range for the local inbound / Clash API ports.
    public static let portRange: ClosedRange<Int> = 1...65535

    /// Local mixed (HTTP + SOCKS) inbound port for the sing-box core.
    public var mixedPort: Int
    /// Local Clash-compatible API port (`experimental.clash_api`).
    public var clashAPIPort: Int
    /// User override for the sing-box binary path; `nil` means auto-discover.
    public var singBoxBinaryPathOverride: String?
    /// Currently selected proxy node, if any.
    public var selectedNodeID: UUID?
    /// URL used for node delay testing through the Clash API.
    public var delayTestURL: String
    /// User-defined routing layer: rules, policy groups, rule-sets, DNS, and
    /// the default outbound. Defaults to `.empty`, which reproduces the pre-M3
    /// single-selector behavior, so configs persisted before M3 still load.
    public var routing: RoutingConfig
    /// Whether subscriptions are refreshed automatically on an interval.
    /// Defaults to `false` (manual refresh only) for predictability.
    public var subscriptionAutoUpdateEnabled: Bool
    /// Interval, in minutes, between automatic subscription refreshes when
    /// `subscriptionAutoUpdateEnabled` is on. Clamped to at least 5 minutes.
    public var subscriptionAutoUpdateMinutes: Int
    /// UI-facing mirror of the "launch at login" registration. The source of
    /// truth is `LoginItemControlling.status`; this is persisted so the toggle
    /// reflects the user's intent across launches even before the service is
    /// queried. Not consulted by the core lifecycle.
    public var launchAtLogin: Bool
    /// How traffic is intercepted: local system proxy (default) or TUN global
    /// mode (M2, runs in a NetworkExtension). Defaults to `.systemProxy` so
    /// preferences persisted before M2 keep the original behavior.
    public var proxyMode: ProxyMode

    /// Minimum allowed auto-update interval; a too-short interval would hammer
    /// the subscription host.
    public static let minAutoUpdateMinutes = 5

    public init(
        mixedPort: Int = 7890,
        clashAPIPort: Int = 9090,
        singBoxBinaryPathOverride: String? = nil,
        selectedNodeID: UUID? = nil,
        delayTestURL: String = "http://www.gstatic.com/generate_204",
        routing: RoutingConfig = .empty,
        subscriptionAutoUpdateEnabled: Bool = false,
        subscriptionAutoUpdateMinutes: Int = 60,
        launchAtLogin: Bool = false,
        proxyMode: ProxyMode = .systemProxy
    ) {
        self.mixedPort = Self.clampPort(mixedPort, fallback: 7890)
        self.clashAPIPort = Self.clampPort(clashAPIPort, fallback: 9090)
        self.singBoxBinaryPathOverride = singBoxBinaryPathOverride
        self.selectedNodeID = selectedNodeID
        self.delayTestURL = delayTestURL
        self.routing = routing
        self.subscriptionAutoUpdateEnabled = subscriptionAutoUpdateEnabled
        self.subscriptionAutoUpdateMinutes = Self.clampInterval(subscriptionAutoUpdateMinutes)
        self.launchAtLogin = launchAtLogin
        self.proxyMode = proxyMode
    }

    public static let `default` = AppPreferences()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences.default
        let rawMixedPort = try container.decodeIfPresent(Int.self, forKey: .mixedPort) ?? defaults.mixedPort
        let rawClashPort = try container.decodeIfPresent(Int.self, forKey: .clashAPIPort) ?? defaults.clashAPIPort
        self.mixedPort = Self.clampPort(rawMixedPort, fallback: defaults.mixedPort)
        self.clashAPIPort = Self.clampPort(rawClashPort, fallback: defaults.clashAPIPort)
        self.singBoxBinaryPathOverride = try container.decodeIfPresent(String.self, forKey: .singBoxBinaryPathOverride)
        self.selectedNodeID = try container.decodeIfPresent(UUID.self, forKey: .selectedNodeID)
        self.delayTestURL = try container.decodeIfPresent(String.self, forKey: .delayTestURL) ?? defaults.delayTestURL
        self.routing = try container.decodeIfPresent(RoutingConfig.self, forKey: .routing) ?? .empty
        self.subscriptionAutoUpdateEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .subscriptionAutoUpdateEnabled
        ) ?? defaults.subscriptionAutoUpdateEnabled
        let rawInterval = try container.decodeIfPresent(
            Int.self, forKey: .subscriptionAutoUpdateMinutes
        ) ?? defaults.subscriptionAutoUpdateMinutes
        self.subscriptionAutoUpdateMinutes = Self.clampInterval(rawInterval)
        self.launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        self.proxyMode = try container.decodeIfPresent(ProxyMode.self, forKey: .proxyMode) ?? defaults.proxyMode
    }

    /// Clamps a port into the valid 1–65535 range, substituting `fallback`
    /// for an out-of-range value (e.g. a corrupted persisted 0 or 70000).
    public static func clampPort(_ port: Int, fallback: Int) -> Int {
        portRange.contains(port) ? port : fallback
    }

    /// Clamps an auto-update interval to at least `minAutoUpdateMinutes`.
    public static func clampInterval(_ minutes: Int) -> Int {
        max(minAutoUpdateMinutes, minutes)
    }
}
