import Foundation

/// Builds the top-level `dns` block using the modern (sing-box 1.12+) typed
/// server format. Emits nothing when DNS is disabled, preserving pre-M3
/// behavior (the core then uses the system resolver).
///
/// The legacy `{address: "https://..."}` server format was made a fatal error
/// in sing-box 1.13 (removed in 1.14), so each `DNSServer.address` URL is
/// parsed into an explicit `{type, server, server_port, path}` object. A
/// bootstrap `local` server is always injected so hostname-based DNS servers
/// and outbound server domains can be resolved; its tag is surfaced as
/// `resolverTag` for the caller to wire into `route.default_domain_resolver`.
///
/// Field names verified with `sing-box check` against the 1.13 core and:
/// - https://sing-box.sagernet.org/configuration/dns/
/// - https://sing-box.sagernet.org/configuration/dns/server/
/// - https://sing-box.sagernet.org/configuration/dns/rule/
/// - https://sing-box.sagernet.org/migration/
struct DNSBuilder {
    /// Reserved tag for the injected bootstrap resolver (system DNS).
    static let bootstrapResolverTag = "dns-local"

    /// The compiled DNS block plus the resolver tag the route layer should use
    /// for `default_domain_resolver`.
    struct Result {
        var dns: [String: Any]
        var resolverTag: String
    }

    /// Reserved base tag for the synthesized static-hosts server.
    static let hostsServerTag = "hosts"

    /// Returns the `dns` block + resolver tag, or `nil` when DNS is disabled and
    /// no static hosts are defined (no block emitted, so the caller must not set
    /// `default_domain_resolver`). Non-empty static `hosts` produce a block even
    /// when the master switch is off, so host mapping works on its own.
    func dnsResult(for config: DNSConfig) -> Result? {
        // Static host mappings reduced to {domain: [ip,...]}, keeping only
        // enabled entries with a domain and at least one IP literal.
        let hostMap = hostPredefinedMap(config.hosts)
        guard config.isEnabled || !hostMap.isEmpty else { return nil }

        var servers: [[String: Any]] = []

        // Inject a bootstrap local resolver (system DNS) unless the user already
        // declared a `local` server we can reuse. It resolves hostname-based DNS
        // servers and outbound domains without a circular dependency.
        let userLocalTag = config.servers.first { isLocalAddress($0.address) }?.tag
        let resolverTag = userLocalTag ?? Self.bootstrapResolverTag
        if userLocalTag == nil {
            servers.append(["type": "local", "tag": Self.bootstrapResolverTag])
        }

        var hasFakeIPServer = false
        for server in config.servers {
            let object = serverObject(for: server, resolverTag: resolverTag, fakeIP: config.fakeIP)
            if object["type"] as? String == "fakeip" { hasFakeIPServer = true }
            servers.append(object)
        }

        // FakeIP becomes a typed server in the new format (off by default; it
        // pairs with TUN/M2). Append a dedicated one only when enabled and the
        // user hasn't already declared a fakeip server. Rules must target it
        // explicitly to take effect.
        if config.fakeIP.enabled, !hasFakeIPServer {
            servers.append([
                "type": "fakeip",
                "tag": "fakeip",
                "inet4_range": config.fakeIP.inet4Range,
                "inet6_range": config.fakeIP.inet6Range,
            ])
        }

        // Static hosts: a single `{type: "hosts"}` server carrying the whole
        // domain→IP map. Its tag is uniqued against the user's server tags so a
        // user server literally named "hosts" can't collide with it.
        var hostsRule: [String: Any]?
        if !hostMap.isEmpty {
            let usedTags = Set(config.servers.map(\.tag))
            let hostsTag = uniqueTag(Self.hostsServerTag, avoiding: usedTags)
            servers.append([
                "type": "hosts",
                "tag": hostsTag,
                "predefined": hostMap,
            ])
            // Route exactly the mapped domains to the hosts server. This rule is
            // prepended so a static mapping always wins over upstream resolvers.
            hostsRule = [
                "action": "route",
                "server": hostsTag,
                "domain": Array(hostMap.keys).sorted(),
            ]
        }

        var dns: [String: Any] = ["servers": servers]

        var rules = config.rules
            .filter(\.isEnabled)
            .compactMap(ruleObject(for:))
        if let hostsRule {
            rules.insert(hostsRule, at: 0)
        }
        if !rules.isEmpty {
            dns["rules"] = rules
        }

        if let finalTag = config.finalServerTag, !finalTag.isEmpty {
            dns["final"] = finalTag
        }
        if let strategy = config.strategy {
            dns["strategy"] = strategy.rawValue
        }
        if config.disableCache {
            dns["disable_cache"] = true
        }

        return Result(dns: dns, resolverTag: resolverTag)
    }

    // MARK: - Servers

    /// Parses a `DNSServer.address` URL into a typed server object.
    private func serverObject(for server: DNSServer, resolverTag: String, fakeIP: FakeIPConfig) -> [String: Any] {
        var object = parsedAddress(server.address)
        object["tag"] = server.tag

        // A fakeip server carries the configured address ranges.
        if object["type"] as? String == "fakeip" {
            object["inet4_range"] = fakeIP.inet4Range
            object["inet6_range"] = fakeIP.inet6Range
        }

        if let detour = server.detour, !detour.isEmpty {
            object["detour"] = detour
        }
        if let strategy = server.strategy {
            object["strategy"] = strategy.rawValue
        }

        // A hostname-based server (not an IP, not `local`/`fakeip`) needs a
        // resolver to look up its own address; point it at the bootstrap unless
        // it is itself the bootstrap.
        if let host = object["server"] as? String,
           server.tag != resolverTag,
           !isIPLiteral(host) {
            object["domain_resolver"] = resolverTag
        }

        return object
    }

    /// Maps an address URL like `tls://1.1.1.1:853`, `https://dns.google/dns-query`,
    /// `udp://8.8.8.8`, `local`, or a bare `223.5.5.5` to a typed server object
    /// (without `tag`).
    private func parsedAddress(_ address: String) -> [String: Any] {
        let trimmed = address.trimmingCharacters(in: .whitespaces)

        if isLocalAddress(trimmed) {
            return ["type": "local"]
        }
        if trimmed.lowercased() == "fakeip" {
            return ["type": "fakeip"]
        }

        let (scheme, rest) = splitScheme(trimmed)
        let type: String
        switch scheme {
        case "https": type = "https"
        case "h3", "http3": type = "h3"
        case "tls": type = "tls"
        case "quic": type = "quic"
        case "tcp": type = "tcp"
        case "udp", "", "dns": type = "udp"
        default: type = "udp"
        }

        // Separate an optional /path (DoH) from host[:port].
        var hostPort = rest
        var path: String?
        if let slash = rest.firstIndex(of: "/") {
            hostPort = String(rest[..<slash])
            let p = String(rest[slash...])
            path = p.isEmpty || p == "/" ? nil : p
        }

        let (host, port) = splitHostPort(hostPort)
        var object: [String: Any] = ["type": type, "server": host]
        if let port { object["server_port"] = port }
        if type == "https" || type == "h3" {
            object["path"] = path ?? "/dns-query"
        }
        return object
    }

    private func splitScheme(_ s: String) -> (scheme: String, rest: String) {
        guard let range = s.range(of: "://") else { return ("", s) }
        return (String(s[..<range.lowerBound]).lowercased(), String(s[range.upperBound...]))
    }

    /// Splits `host[:port]`, honoring bracketed IPv6 literals (`[::1]:53`).
    private func splitHostPort(_ s: String) -> (host: String, port: Int?) {
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return (s, nil) }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            if after.hasPrefix(":"), let port = Int(after.dropFirst()) {
                return (host, port)
            }
            return (host, nil)
        }
        // A bare IPv6 literal has multiple colons and no port.
        if s.filter({ $0 == ":" }).count > 1 {
            return (s, nil)
        }
        if let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) {
            return (String(s[..<colon]), port)
        }
        return (s, nil)
    }

    private func isLocalAddress(_ s: String) -> Bool {
        let v = s.trimmingCharacters(in: .whitespaces).lowercased()
        return v == "local" || v == "localdns" || v == "system"
    }

    /// True for bare IPv4/IPv6 literals (no DNS resolution needed).
    private func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return true }
        return false
    }

    // MARK: - Rules

    private func ruleObject(for rule: DNSRule) -> [String: Any]? {
        let values = splitValues(rule.value)
        guard !values.isEmpty, !rule.server.isEmpty else { return nil }

        var object: [String: Any] = [
            "action": "route",
            "server": rule.server,
        ]

        switch rule.matcher {
        case .domain:
            object["domain"] = values
        case .domainSuffix:
            object["domain_suffix"] = values
        case .domainKeyword:
            object["domain_keyword"] = values
        case .domainRegex:
            object["domain_regex"] = values
        case .geosite, .ruleSet:
            object["rule_set"] = values
        case .clashMode:
            object["clash_mode"] = values[0]
        }

        return object
    }

    // MARK: - Static hosts

    /// Reduces the configured `HostEntry` list to a sing-box `predefined` map
    /// (`{domain: [ip,...]}`), keeping only enabled entries that carry a domain
    /// and at least one IP literal. Later entries for the same domain win (the
    /// UI presents them top-down). Non-IP addresses are dropped — the `hosts`
    /// server only answers with literal addresses, never CNAMEs.
    private func hostPredefinedMap(_ hosts: [HostEntry]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for entry in hosts where entry.isEnabled {
            guard let domain = entry.trimmedDomain else { continue }
            let ips = entry.addressList.filter(isIPLiteral)
            guard !ips.isEmpty else { continue }
            map[domain] = ips
        }
        return map
    }

    /// Returns `base` if free, else `base-2`, `base-3`, … avoiding `taken`.
    private func uniqueTag(_ base: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: - Helpers

    private func splitValues(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
