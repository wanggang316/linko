import Foundation

/// Domain resolution strategy, mapped to `dns.strategy` (and reused for
/// per-server strategy).
///
/// See https://sing-box.sagernet.org/configuration/dns/
public enum DNSStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case preferIPv4 = "prefer_ipv4"
    case preferIPv6 = "prefer_ipv6"
    case ipv4Only = "ipv4_only"
    case ipv6Only = "ipv6_only"
}

/// A DNS server, emitted to `dns.servers` using the legacy address-string
/// format (`{tag, address, detour, strategy, address_resolver}`).
///
/// `address` carries the full transport URL the user enters, e.g.
/// `tls://1.1.1.1`, `https://1.1.1.1/dns-query`, `quic://dns.adguard.com`,
/// `h3://8.8.8.8/dns-query`, `udp://8.8.8.8`, `local`, or `fakeip`.
///
/// See https://sing-box.sagernet.org/configuration/dns/server/legacy/
public struct DNSServer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// `dns.servers[].tag` — referenced by DNS rules and `dns.final`.
    public var tag: String
    /// `dns.servers[].address` — the full DNS transport URL.
    public var address: String
    /// `dns.servers[].detour` — outbound tag used to reach this server
    /// (e.g. "direct" for a domestic resolver). `nil` ⇒ field omitted.
    public var detour: String?
    /// `dns.servers[].address_resolver` — tag of another server used to resolve
    /// this server's hostname. `nil` ⇒ field omitted.
    public var addressResolver: String?
    /// `dns.servers[].strategy` — per-server resolution strategy. `nil` ⇒ omitted.
    public var strategy: DNSStrategy?

    public init(
        id: UUID = UUID(),
        tag: String,
        address: String,
        detour: String? = nil,
        addressResolver: String? = nil,
        strategy: DNSStrategy? = nil
    ) {
        self.id = id
        self.tag = tag
        self.address = address
        self.detour = detour
        self.addressResolver = addressResolver
        self.strategy = strategy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.tag = try c.decode(String.self, forKey: .tag)
        self.address = try c.decode(String.self, forKey: .address)
        self.detour = try c.decodeIfPresent(String.self, forKey: .detour)
        self.addressResolver = try c.decodeIfPresent(String.self, forKey: .addressResolver)
        self.strategy = try c.decodeIfPresent(DNSStrategy.self, forKey: .strategy)
    }
}

/// What a DNS rule matches on. Each maps to a `dns.rules[]` matcher field.
///
/// See https://sing-box.sagernet.org/configuration/dns/rule/
public enum DNSRuleMatcher: String, Codable, CaseIterable, Hashable, Sendable {
    case domain                                // -> domain
    case domainSuffix = "domain_suffix"        // -> domain_suffix
    case domainKeyword = "domain_keyword"      // -> domain_keyword
    case domainRegex = "domain_regex"          // -> domain_regex
    case geosite                               // -> rule_set (geosite)
    case ruleSet = "rule_set"                  // -> rule_set (by tag)
    case clashMode = "clash_mode"              // -> clash_mode
}

/// A DNS routing rule, emitted to `dns.rules`. Matches a set of domains/sites
/// and directs them to a `server` tag.
///
/// See https://sing-box.sagernet.org/configuration/dns/rule/
public struct DNSRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var matcher: DNSRuleMatcher
    /// Literal value for the matcher, or a rule-set/geosite tag for the
    /// rule-set matchers. Comma-separated entries are split by the engine.
    public var value: String
    /// `dns.rules[].server` — the target DNS server tag.
    public var server: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        matcher: DNSRuleMatcher,
        value: String,
        server: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.matcher = matcher
        self.value = value
        self.server = server
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.matcher = try c.decode(DNSRuleMatcher.self, forKey: .matcher)
        self.value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.server = try c.decode(String.self, forKey: .server)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// FakeIP settings, mapped to `dns.fakeip`. Off by default in system-proxy
/// mode; intended to pair with TUN (M2).
///
/// See https://sing-box.sagernet.org/configuration/dns/fakeip/
public struct FakeIPConfig: Codable, Hashable, Sendable {
    /// `dns.fakeip.enabled`.
    public var enabled: Bool
    /// `dns.fakeip.inet4_range`.
    public var inet4Range: String
    /// `dns.fakeip.inet6_range`.
    public var inet6Range: String

    public init(
        enabled: Bool = false,
        inet4Range: String = "198.18.0.0/15",
        inet6Range: String = "fc00::/18"
    ) {
        self.enabled = enabled
        self.inet4Range = inet4Range
        self.inet6Range = inet6Range
    }

    public static let disabled = FakeIPConfig()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.inet4Range = try c.decodeIfPresent(String.self, forKey: .inet4Range) ?? "198.18.0.0/15"
        self.inet6Range = try c.decodeIfPresent(String.self, forKey: .inet6Range) ?? "fc00::/18"
    }
}

/// The complete DNS configuration, compiled to the sing-box `dns` block.
///
/// When `isEnabled` is `false`, the builder omits the `dns` block entirely and
/// the core falls back to its default behavior (preserving pre-M3 behavior).
public struct DNSConfig: Codable, Hashable, Sendable {
    /// Master switch. `false` ⇒ no `dns` block emitted.
    public var isEnabled: Bool
    /// `dns.servers`.
    public var servers: [DNSServer]
    /// `dns.rules`.
    public var rules: [DNSRule]
    /// `dns.final` — fallback server tag. `nil` ⇒ omitted (first server used).
    public var finalServerTag: String?
    /// `dns.strategy`.
    public var strategy: DNSStrategy?
    /// `dns.disable_cache`.
    public var disableCache: Bool
    /// `dns.fakeip`.
    public var fakeIP: FakeIPConfig

    public init(
        isEnabled: Bool = false,
        servers: [DNSServer] = [],
        rules: [DNSRule] = [],
        finalServerTag: String? = nil,
        strategy: DNSStrategy? = nil,
        disableCache: Bool = false,
        fakeIP: FakeIPConfig = .disabled
    ) {
        self.isEnabled = isEnabled
        self.servers = servers
        self.rules = rules
        self.finalServerTag = finalServerTag
        self.strategy = strategy
        self.disableCache = disableCache
        self.fakeIP = fakeIP
    }

    /// Empty/disabled DNS — the builder emits nothing and the core defaults
    /// apply. This is the value old preferences decode to.
    public static let disabled = DNSConfig()

    /// A sensible starter config: a domestic resolver reached via "direct",
    /// an encrypted upstream via the proxy, and a geosite-cn rule pointing at
    /// the domestic server. Used to seed the DNS editor, never auto-applied.
    public static func recommended() -> DNSConfig {
        DNSConfig(
            isEnabled: true,
            servers: [
                DNSServer(tag: "dns-domestic", address: "https://223.5.5.5/dns-query", detour: "direct"),
                DNSServer(tag: "dns-proxy", address: "tls://1.1.1.1"),
            ],
            rules: [
                DNSRule(matcher: .ruleSet, value: "geosite-cn", server: "dns-domestic"),
            ],
            finalServerTag: "dns-proxy",
            strategy: .preferIPv4
        )
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.servers = try c.decodeIfPresent([DNSServer].self, forKey: .servers) ?? []
        self.rules = try c.decodeIfPresent([DNSRule].self, forKey: .rules) ?? []
        self.finalServerTag = try c.decodeIfPresent(String.self, forKey: .finalServerTag)
        self.strategy = try c.decodeIfPresent(DNSStrategy.self, forKey: .strategy)
        self.disableCache = try c.decodeIfPresent(Bool.self, forKey: .disableCache) ?? false
        self.fakeIP = try c.decodeIfPresent(FakeIPConfig.self, forKey: .fakeIP) ?? .disabled
    }
}
