import Foundation

/// The kind of match a routing rule performs.
///
/// Raw values are the Surge/Clash-style names shown in the UI and used by the
/// rule importer; each maps to a sing-box `route.rule` field documented at
/// https://sing-box.sagernet.org/configuration/route/rule/
public enum RuleType: String, Codable, CaseIterable, Hashable, Sendable {
    // Domain matchers
    case domain = "DOMAIN"                     // -> domain
    case domainSuffix = "DOMAIN-SUFFIX"        // -> domain_suffix
    case domainKeyword = "DOMAIN-KEYWORD"      // -> domain_keyword
    case domainRegex = "DOMAIN-REGEX"          // -> domain_regex
    // IP matchers
    case ipCIDR = "IP-CIDR"                    // -> ip_cidr
    case ipCIDR6 = "IP-CIDR6"                  // -> ip_cidr
    case srcIPCIDR = "SRC-IP-CIDR"             // -> source_ip_cidr
    case geoip = "GEOIP"                       // -> rule_set (geoip)
    // Geosite
    case geosite = "GEOSITE"                   // -> rule_set (geosite)
    // Remote / local rule sets (sing-box .srs or clash-style)
    case ruleSet = "RULE-SET"                  // -> rule_set (remote/local entry)
    // Process matchers
    case processName = "PROCESS-NAME"          // -> process_name
    case processPath = "PROCESS-PATH"          // -> process_path
    // Port matchers
    case port = "PORT"                         // -> port
    case destPort = "DEST-PORT"                // -> port
    case srcPort = "SRC-PORT"                  // -> source_port
    // Protocol / network
    case network = "NETWORK"                   // -> network (tcp/udp)
    case protocolSniff = "PROTOCOL"            // -> protocol (sniffed)
    // Logical combinators
    case and = "AND"                           // -> {type:"logical", mode:"and"}
    case or = "OR"                             // -> {type:"logical", mode:"or"}
    case not = "NOT"                           // -> {type:"logical", mode:"and", invert:true}
    // Catch-all
    case final = "FINAL"                       // -> route.final

    /// `true` for logical combinators that hold sub-rules in `subRules`.
    public var isLogical: Bool {
        self == .and || self == .or || self == .not
    }

    /// `true` for the catch-all that compiles to `route.final` rather than a
    /// `route.rules` entry.
    public var isFinal: Bool { self == .final }

    /// `true` when the rule references a managed rule-set entry by tag
    /// (its `value` is the rule-set tag) rather than carrying a literal value.
    public var usesRuleSet: Bool {
        self == .geoip || self == .geosite || self == .ruleSet
    }
}

/// A single routing rule that compiles to a sing-box `route.rules` entry (or,
/// for `.final`, to `route.final`).
///
/// `value` holds the literal payload for leaf matchers (a domain, CIDR, port,
/// process name, or — for rule-set kinds — the rule-set tag). `subRules` holds
/// the operands of a logical combinator and is empty for leaves. `target` is
/// the outbound tag (a node tag or a `PolicyGroup` tag) the matched traffic is
/// routed to; for `.final` it is the default outbound.
public struct RoutingRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var type: RuleType
    /// Literal payload for leaf matchers; rule-set tag for rule-set kinds;
    /// ignored for logical combinators.
    public var value: String
    /// Operands for logical combinators (`AND`/`OR`/`NOT`); empty for leaves.
    public var subRules: [RoutingRule]
    /// Outbound tag this rule routes to (node tag or policy-group tag); for
    /// `.final` it is the default outbound tag.
    public var target: String
    /// Whether this rule participates in config generation. Disabled rules are
    /// kept in the model (and editor) but skipped by the builder.
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        type: RuleType,
        value: String = "",
        subRules: [RoutingRule] = [],
        target: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.subRules = subRules
        self.target = target
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.type = try c.decode(RuleType.self, forKey: .type)
        self.value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.subRules = try c.decodeIfPresent([RoutingRule].self, forKey: .subRules) ?? []
        self.target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// A managed rule-set referenced by `GEOIP`/`GEOSITE`/`RULE-SET` rules and
/// emitted under `route.rule_set`.
///
/// See https://sing-box.sagernet.org/configuration/rule-set/
public struct RuleSetEntry: Codable, Hashable, Identifiable, Sendable {
    /// `route.rule_set[].tag`. Also the value a rule references.
    public var tag: String
    /// `local` vs `remote`.
    public var source: RuleSetSource
    /// `binary` (.srs) vs `source` (.json) — `route.rule_set[].format`.
    public var format: RuleSetFormat
    /// `route.rule_set[].url` (remote only).
    public var url: String?
    /// `route.rule_set[].path` (local only).
    public var path: String?
    /// `route.rule_set[].download_detour` — outbound tag used to fetch a
    /// remote rule-set (typically "direct").
    public var downloadDetour: String?
    /// `route.rule_set[].update_interval`, e.g. "1d". Remote only.
    public var updateInterval: String?

    public var id: String { tag }

    public init(
        tag: String,
        source: RuleSetSource = .remote,
        format: RuleSetFormat = .binary,
        url: String? = nil,
        path: String? = nil,
        downloadDetour: String? = "direct",
        updateInterval: String? = "1d"
    ) {
        self.tag = tag
        self.source = source
        self.format = format
        self.url = url
        self.path = path
        self.downloadDetour = downloadDetour
        self.updateInterval = updateInterval
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tag = try c.decode(String.self, forKey: .tag)
        self.source = try c.decodeIfPresent(RuleSetSource.self, forKey: .source) ?? .remote
        self.format = try c.decodeIfPresent(RuleSetFormat.self, forKey: .format) ?? .binary
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.path = try c.decodeIfPresent(String.self, forKey: .path)
        self.downloadDetour = try c.decodeIfPresent(String.self, forKey: .downloadDetour)
        self.updateInterval = try c.decodeIfPresent(String.self, forKey: .updateInterval)
    }
}

/// `route.rule_set[].type`.
public enum RuleSetSource: String, Codable, CaseIterable, Hashable, Sendable {
    case local
    case remote
}

/// `route.rule_set[].format`.
public enum RuleSetFormat: String, Codable, CaseIterable, Hashable, Sendable {
    /// Compiled `.srs`.
    case binary
    /// Plain `.json` source.
    case source
}
