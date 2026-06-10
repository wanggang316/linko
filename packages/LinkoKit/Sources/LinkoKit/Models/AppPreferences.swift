import Foundation

/// User-configurable application preferences, persisted as JSON under
/// `~/Library/Application Support/linko/`.
public struct AppPreferences: Codable, Equatable, Sendable {
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

    public init(
        mixedPort: Int = 7890,
        clashAPIPort: Int = 9090,
        singBoxBinaryPathOverride: String? = nil,
        selectedNodeID: UUID? = nil,
        delayTestURL: String = "http://www.gstatic.com/generate_204",
        routing: RoutingConfig = .empty
    ) {
        self.mixedPort = mixedPort
        self.clashAPIPort = clashAPIPort
        self.singBoxBinaryPathOverride = singBoxBinaryPathOverride
        self.selectedNodeID = selectedNodeID
        self.delayTestURL = delayTestURL
        self.routing = routing
    }

    public static let `default` = AppPreferences()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences.default
        self.mixedPort = try container.decodeIfPresent(Int.self, forKey: .mixedPort) ?? defaults.mixedPort
        self.clashAPIPort = try container.decodeIfPresent(Int.self, forKey: .clashAPIPort) ?? defaults.clashAPIPort
        self.singBoxBinaryPathOverride = try container.decodeIfPresent(String.self, forKey: .singBoxBinaryPathOverride)
        self.selectedNodeID = try container.decodeIfPresent(UUID.self, forKey: .selectedNodeID)
        self.delayTestURL = try container.decodeIfPresent(String.self, forKey: .delayTestURL) ?? defaults.delayTestURL
        self.routing = try container.decodeIfPresent(RoutingConfig.self, forKey: .routing) ?? .empty
    }
}
