import Foundation

/// Errors produced while turning `ProxyNode`s into a sing-box configuration.
public enum SingBoxConfigError: Error, Equatable, LocalizedError {
    case noNodes
    case missingField(node: String, field: String)
    /// A WireGuard node reached the outbound builder; it must be emitted as a
    /// top-level `endpoints[]` entry instead (sing-box 1.11+).
    case wireGuardIsEndpoint(node: String)

    public var errorDescription: String? {
        switch self {
        case .noNodes:
            return "Cannot build a sing-box config without any proxy nodes."
        case let .missingField(node, field):
            return "Node \"\(node)\" is missing the required field \"\(field)\"."
        case let .wireGuardIsEndpoint(node):
            return "WireGuard node \"\(node)\" must be emitted as an endpoint, not an outbound."
        }
    }
}

/// Builds a complete sing-box 1.x JSON configuration from proxy nodes and
/// user preferences. See `SingBoxConfigBuilding` for the produced shape.
///
/// With an empty `preferences.routing` the output is byte-for-byte equivalent to
/// the M1 baseline (mixed inbound, one outbound per node, a single "proxy"
/// selector, a direct outbound, `route.final = "proxy"`). When routing is
/// populated, the builder additionally emits policy-group outbounds, `route.rules`
/// (including logical nesting and rule-sets), `route.rule_set`, `route.final`
/// from `routing.finalTarget`, and a `dns` block when `routing.dns.isEnabled`.
public struct SingBoxConfigBuilder: SingBoxConfigBuilding {
    /// Tags reserved for non-node outbounds; node tags must never collide
    /// with these.
    private static let reservedTags: Set<String> = ["proxy", "direct"]

    private let outboundBuilder = OutboundBuilder()
    private let dnsBuilder = DNSBuilder()

    public init() {}

    /// Returns the outbound tag assigned to each node, positionally aligned
    /// with `nodes` — the exact assignment `build` uses. Callers must address
    /// nodes through the Clash API by these tags, because display names may
    /// collide and get deduplicated here.
    public func outboundTags(for nodes: [ProxyNode]) -> [String] {
        var usedTags = Self.reservedTags
        return nodes.map { uniqueTag(for: $0.name, used: &usedTags) }
    }

    /// Validates `routing` against `nodes`: every rule/group/DNS/final target
    /// must resolve to a node tag, a defined group, or a built-in ("direct"/
    /// "proxy"); rule-set references must exist; group nesting must not cycle.
    /// Soft problems return warnings; the config still builds (dropping the
    /// offending pieces). There are currently no hard errors that throw here —
    /// `build` itself throws only on missing node fields / empty node lists.
    public func validate(nodes: [ProxyNode], routing: RoutingConfig) throws -> [String] {
        var warnings: [String] = []
        let nodeTags = outboundTags(for: nodes)
        var resolvable = Set(nodeTags)
        resolvable.formUnion(routing.groups.map(\.name))
        resolvable.insert("direct")
        resolvable.insert(PolicyGroup.defaultGroupName)
        let ruleSetTags = Set(routing.ruleSets.map(\.tag))
        let groupNames = Set(routing.groups.map(\.name))

        // Rule targets + rule-set references.
        validateRuleTargets(routing.rules, resolvable: resolvable, ruleSetTags: ruleSetTags, warnings: &warnings)

        // Group membership + nesting cycles.
        for group in routing.groups {
            for member in group.members {
                switch member.kind {
                case .node where !nodeTags.contains(member.tag):
                    warnings.append("策略组 “\(group.name)” 引用了未知节点 “\(member.tag)”。")
                case .group where !groupNames.contains(member.tag):
                    warnings.append("策略组 “\(group.name)” 引用了未知策略组 “\(member.tag)”。")
                default:
                    break
                }
            }
        }
        if let cycle = firstGroupCycle(in: routing.groups) {
            warnings.append("策略组存在循环引用：\(cycle.joined(separator: " → "))。")
        }

        // Final target.
        if !resolvable.contains(routing.finalTarget) {
            warnings.append("route.final 目标 “\(routing.finalTarget)” 未找到。")
        }

        // DNS server tags referenced by DNS rules / final.
        if routing.dns.isEnabled {
            let serverTags = Set(routing.dns.servers.map(\.tag))
            for rule in routing.dns.rules where rule.isEnabled {
                if !serverTags.contains(rule.server) {
                    warnings.append("DNS 规则引用了未知服务器 “\(rule.server)”。")
                }
            }
            if let finalTag = routing.dns.finalServerTag, !finalTag.isEmpty, !serverTags.contains(finalTag) {
                warnings.append("dns.final 引用了未知服务器 “\(finalTag)”。")
            }
        }

        return warnings
    }

    public func build(nodes: [ProxyNode], preferences: AppPreferences) throws -> Data {
        guard !nodes.isEmpty else {
            throw SingBoxConfigError.noNodes
        }

        let routing = preferences.routing
        let nodeTags = outboundTags(for: nodes)

        // Per-node outbounds (and WireGuard endpoints) plus the selected tag.
        // WireGuard migrated to a top-level `endpoints[]` entry in sing-box
        // 1.11+; its tag stays referenceable by rules/groups like any outbound.
        var nodeOutbounds: [[String: Any]] = []
        var nodeEndpoints: [[String: Any]] = []
        var selectedTag: String?
        for (node, tag) in zip(nodes, nodeTags) {
            if node.protocolType.isEndpoint {
                nodeEndpoints.append(try outboundBuilder.endpointObject(for: node, tag: tag))
            } else {
                nodeOutbounds.append(try outboundBuilder.outbound(for: node, tag: tag))
            }
            if let selectedID = preferences.selectedNodeID, node.id == selectedID {
                selectedTag = tag
            }
        }

        // Policy-group outbounds + the route block.
        let route = RouteBuilder(routing: routing, nodeTags: nodeTags)
        let routeResult = route.build(nodeTags: nodeTags, selectedTag: selectedTag)

        // When no user groups exist, synthesize the legacy "proxy" selector over
        // all nodes + direct so M1 behavior is preserved exactly.
        var groupOutbounds = routeResult.groupOutbounds
        if routing.groups.isEmpty {
            groupOutbounds = [legacySelector(nodeTags: nodeTags, selectedTag: selectedTag)]
        }

        let direct: [String: Any] = ["type": "direct", "tag": "direct"]

        var config: [String: Any] = [
            "log": ["level": "info"],
            "inbounds": [inbound(for: preferences)],
            "outbounds": groupOutbounds + nodeOutbounds + [direct],
            "route": routeResult.route,
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:\(preferences.clashAPIPort)"
                ]
            ],
        ]

        // WireGuard nodes live in the top-level `endpoints[]` array (1.11+).
        if !nodeEndpoints.isEmpty {
            config["endpoints"] = nodeEndpoints
        }

        if let dnsResult = dnsBuilder.dnsResult(for: routing.dns) {
            config["dns"] = dnsResult.dns
            // sing-box 1.12+ requires an explicit resolver for outbound server
            // domains once DNS is configured; point it at the bootstrap server.
            var routeWithResolver = routeResult.route
            routeWithResolver["default_domain_resolver"] = ["server": dnsResult.resolverTag]
            config["route"] = routeWithResolver
        }

        if preferences.proxyMode == .tun {
            applyTunDNSGuarantees(to: &config)
        }

        return try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    // MARK: - TUN DNS guarantees

    /// Tag of the DNS server synthesized when the user has DNS management off.
    static let tunFallbackDNSTag = "tun-fallback-dns"

    /// TUN mode cannot function without DNS: `auto_route` + `strict_route`
    /// pull every packet — including the system resolver's own queries — into
    /// the tunnel, so sing-box must (a) be able to resolve outbound server
    /// domains itself and (b) answer the clients' DNS queries. System-proxy
    /// mode needs neither (the OS resolver never enters sing-box there).
    ///
    /// Guarantees applied to a `.tun` config:
    /// - a `dns` block with at least one server (synthesized when the user's
    ///   DNS management is disabled), plus `route.default_domain_resolver`;
    /// - `route.rules` is prefixed with `action: sniff` and
    ///   `protocol: dns → action: hijack-dns` (sing-box 1.11+ rule actions) so
    ///   tunneled DNS queries are answered by the DNS module instead of being
    ///   forwarded — and possibly blackholed — through the final outbound.
    private func applyTunDNSGuarantees(to config: inout [String: Any]) {
        var route = (config["route"] as? [String: Any]) ?? [:]

        if config["dns"] == nil {
            config["dns"] = [
                "servers": [
                    [
                        "tag": Self.tunFallbackDNSTag,
                        "type": "udp",
                        "server": "223.5.5.5",
                        // Resolver traffic must never route back into the
                        // proxy (whose server domain it is busy resolving).
                        "detour": "direct",
                    ] as [String: Any]
                ]
            ]
            route["default_domain_resolver"] = ["server": Self.tunFallbackDNSTag]
        }

        var rules = (route["rules"] as? [[String: Any]]) ?? []
        let hasHijack = rules.contains { ($0["action"] as? String) == "hijack-dns" }
        if !hasHijack {
            rules.insert(["protocol": "dns", "action": "hijack-dns"], at: 0)
            rules.insert(["action": "sniff"], at: 0)
            route["rules"] = rules
        }
        config["route"] = route
    }

    // MARK: - Inbound

    /// The single inbound, chosen by proxy mode. System-proxy mode uses a local
    /// `mixed` (SOCKS+HTTP) listener; TUN mode uses a `tun` inbound that captures
    /// all traffic via a virtual interface (run inside the NetworkExtension).
    private func inbound(for preferences: AppPreferences) -> [String: Any] {
        switch preferences.proxyMode {
        case .systemProxy:
            return [
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": preferences.mixedPort,
            ]
        case .tun:
            // address/auto_route per sing-box 1.12+ (unified `address` array).
            // The NetworkExtension supplies the tun fd via libbox; gVisor is the
            // portable userspace stack. fake-ip DNS (when enabled) pairs here.
            return [
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": 9000,
                "auto_route": true,
                "strict_route": true,
                "stack": "gvisor",
            ]
        }
    }

    // MARK: - Legacy selector (empty-routing path)

    private func legacySelector(nodeTags: [String], selectedTag: String?) -> [String: Any] {
        var selector: [String: Any] = [
            "type": "selector",
            "tag": "proxy",
            "outbounds": nodeTags + ["direct"],
        ]
        if let selectedTag {
            selector["default"] = selectedTag
        }
        return selector
    }

    // MARK: - Validation helpers

    private func validateRuleTargets(
        _ rules: [RoutingRule],
        resolvable: Set<String>,
        ruleSetTags: Set<String>,
        warnings: inout [String]
    ) {
        for rule in rules where rule.isEnabled {
            if !rule.type.isFinal, !resolvable.contains(rule.target) {
                warnings.append("规则目标 “\(rule.target)” 未找到。")
            }
            if rule.type.usesRuleSet {
                for tag in rule.value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
                where !tag.isEmpty && !ruleSetTags.contains(tag) {
                    warnings.append("规则引用了未定义的规则集 “\(tag)”。")
                }
            }
            if rule.type.isLogical {
                validateRuleTargets(rule.subRules, resolvable: resolvable, ruleSetTags: ruleSetTags, warnings: &warnings)
            }
        }
    }

    /// Detects the first cycle among `.group` members, returning the offending
    /// chain of names, or `nil` when the membership graph is acyclic.
    private func firstGroupCycle(in groups: [PolicyGroup]) -> [String]? {
        let byName = Dictionary(groups.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var state: [String: Int] = [:] // 0 = visiting, 1 = done

        func visit(_ name: String, stack: [String]) -> [String]? {
            if state[name] == 1 { return nil }
            if state[name] == 0 {
                // Found a back-edge: trim the stack to the cycle start.
                if let idx = stack.firstIndex(of: name) {
                    return Array(stack[idx...]) + [name]
                }
                return stack + [name]
            }
            state[name] = 0
            if let group = byName[name] {
                for member in group.members where member.kind == .group {
                    if let cycle = visit(member.tag, stack: stack + [name]) {
                        return cycle
                    }
                }
            }
            state[name] = 1
            return nil
        }

        for group in groups {
            if let cycle = visit(group.name, stack: []) {
                return cycle
            }
        }
        return nil
    }

    // MARK: - Tagging

    /// Returns a tag for `name` that does not collide with reserved tags or
    /// previously assigned node tags, appending a numeric suffix when needed.
    private func uniqueTag(for name: String, used: inout Set<String>) -> String {
        let base = name.isEmpty ? "node" : name
        var candidate = base
        var counter = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }
}
