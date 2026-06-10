import Foundation

/// The complete user-defined routing layer: ordered rules, policy groups, the
/// rule-sets those rules reference, the DNS config, and the default outbound.
///
/// This is the single value persisted in `AppPreferences.routing` and consumed
/// by the config builder to emit `route` + `dns`. It is intentionally tolerant:
/// an empty `RoutingConfig` reproduces the pre-M3 behavior (single "proxy"
/// selector, `route.final = "proxy"`, no `dns` block).
public struct RoutingConfig: Codable, Hashable, Sendable {
    /// Ordered routing rules. Order is significant — the builder emits them to
    /// `route.rules` in this order (first match wins). `.final` rules are
    /// folded into `route.final` and not emitted as list entries.
    public var rules: [RoutingRule]

    /// User-defined policy groups. The group named `finalTarget` (default
    /// "proxy") acts as the default outbound. When empty, the engine
    /// synthesizes the legacy "proxy" selector over all nodes.
    public var groups: [PolicyGroup]

    /// Rule-sets referenced by `GEOIP`/`GEOSITE`/`RULE-SET` rules and DNS
    /// rule-set matchers, emitted under `route.rule_set`.
    public var ruleSets: [RuleSetEntry]

    /// DNS configuration. Disabled by default.
    public var dns: DNSConfig

    /// The outbound tag for `route.final` (a group or node tag, or "direct").
    /// Defaults to the conventional "proxy" group.
    public var finalTarget: String

    /// Whether sniffing/`auto_detect_interface` style route conveniences are
    /// enabled. Kept here so the builder reads one source of truth; defaults
    /// preserve existing behavior.
    public var autoDetectInterface: Bool

    public init(
        rules: [RoutingRule] = [],
        groups: [PolicyGroup] = [],
        ruleSets: [RuleSetEntry] = [],
        dns: DNSConfig = .disabled,
        finalTarget: String = PolicyGroup.defaultGroupName,
        autoDetectInterface: Bool = true
    ) {
        self.rules = rules
        self.groups = groups
        self.ruleSets = ruleSets
        self.dns = dns
        self.finalTarget = finalTarget
        self.autoDetectInterface = autoDetectInterface
    }

    /// The empty routing layer — reproduces pre-M3 behavior. This is what old
    /// preferences decode to.
    public static let empty = RoutingConfig()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.rules = try c.decodeIfPresent([RoutingRule].self, forKey: .rules) ?? []
        self.groups = try c.decodeIfPresent([PolicyGroup].self, forKey: .groups) ?? []
        self.ruleSets = try c.decodeIfPresent([RuleSetEntry].self, forKey: .ruleSets) ?? []
        self.dns = try c.decodeIfPresent(DNSConfig.self, forKey: .dns) ?? .disabled
        self.finalTarget = try c.decodeIfPresent(String.self, forKey: .finalTarget) ?? PolicyGroup.defaultGroupName
        self.autoDetectInterface = try c.decodeIfPresent(Bool.self, forKey: .autoDetectInterface) ?? true
    }
}
