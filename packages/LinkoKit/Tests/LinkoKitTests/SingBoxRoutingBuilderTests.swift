import XCTest
@testable import LinkoKit

/// Golden-JSON tests for the M3 routing layer: policy groups (selector/urltest/
/// nesting), `route.rules` (leaf + logical + rule-set), `route.rule_set`, the
/// `dns` block, and the new transport/TLS/reality/plugin outbound fields.
final class SingBoxRoutingBuilderTests: XCTestCase {
    private let builder = SingBoxConfigBuilder()

    // MARK: - Fixtures

    private func ssNode(_ name: String) -> ProxyNode {
        ProxyNode(name: name, protocolType: .shadowsocks, server: "\(name).example.com",
                  port: 8388, password: "pw", method: "aes-256-gcm")
    }

    private func buildJSON(nodes: [ProxyNode], routing: RoutingConfig) throws -> [String: Any] {
        var prefs = AppPreferences()
        prefs.routing = routing
        let data = try builder.build(nodes: nodes, preferences: prefs)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func outbound(tagged tag: String, in config: [String: Any]) throws -> [String: Any] {
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        return try XCTUnwrap(outbounds.first { $0["tag"] as? String == tag }, "no outbound tagged \(tag)")
    }

    private func route(in config: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(config["route"] as? [String: Any])
    }

    private func rules(in config: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(try route(in: config)["rules"] as? [[String: Any]])
    }

    // MARK: - Multi-rule routing config (golden)

    func testMultiRuleRoutingConfig() throws {
        let routing = RoutingConfig(
            rules: [
                RoutingRule(type: .domainSuffix, value: "google.com", target: "proxy"),
                RoutingRule(type: .domainKeyword, value: "ads", target: "direct"),
                RoutingRule(type: .ipCIDR, value: "10.0.0.0/8", target: "direct"),
                RoutingRule(type: .ipCIDR6, value: "fd00::/8", target: "direct"),
                RoutingRule(type: .port, value: "80,443", target: "proxy"),
                RoutingRule(type: .processName, value: "Telegram", target: "proxy"),
                RoutingRule(type: .geosite, value: "geosite-cn", target: "direct"),
                RoutingRule(type: .final, value: "", target: "proxy"),
            ],
            ruleSets: [
                RuleSetEntry(tag: "geosite-cn", source: .remote, format: .binary,
                             url: "https://example.com/geosite-cn.srs"),
            ],
            finalTarget: "proxy"
        )
        let config = try buildJSON(nodes: [ssNode("A")], routing: routing)
        let rules = try rules(in: config)

        // FINAL is folded into route.final, not a list entry.
        XCTAssertEqual(rules.count, 7)
        XCTAssertEqual(try route(in: config)["final"] as? String, "proxy")

        XCTAssertEqual(rules[0]["domain_suffix"] as? [String], ["google.com"])
        XCTAssertEqual(rules[0]["action"] as? String, "route")
        XCTAssertEqual(rules[0]["outbound"] as? String, "proxy")

        XCTAssertEqual(rules[1]["domain_keyword"] as? [String], ["ads"])
        XCTAssertEqual(rules[1]["outbound"] as? String, "direct")

        // IP-CIDR and IP-CIDR6 both map to ip_cidr.
        XCTAssertEqual(rules[2]["ip_cidr"] as? [String], ["10.0.0.0/8"])
        XCTAssertEqual(rules[3]["ip_cidr"] as? [String], ["fd00::/8"])

        // Comma-separated ports split into an integer array.
        XCTAssertEqual(rules[4]["port"] as? [Int], [80, 443])

        XCTAssertEqual(rules[5]["process_name"] as? [String], ["Telegram"])

        // geosite -> rule_set reference.
        XCTAssertEqual(rules[6]["rule_set"] as? [String], ["geosite-cn"])

        // rule_set entry wired into route.rule_set.
        let ruleSets = try XCTUnwrap(try route(in: config)["rule_set"] as? [[String: Any]])
        XCTAssertEqual(ruleSets.count, 1)
        XCTAssertEqual(ruleSets[0]["tag"] as? String, "geosite-cn")
        XCTAssertEqual(ruleSets[0]["type"] as? String, "remote")
        XCTAssertEqual(ruleSets[0]["format"] as? String, "binary")
        XCTAssertEqual(ruleSets[0]["url"] as? String, "https://example.com/geosite-cn.srs")
        XCTAssertEqual(ruleSets[0]["download_detour"] as? String, "direct")
        XCTAssertEqual(ruleSets[0]["update_interval"] as? String, "1d")
    }

    // MARK: - Logical rules

    func testLogicalAndRule() throws {
        let routing = RoutingConfig(
            rules: [
                RoutingRule(type: .and, subRules: [
                    RoutingRule(type: .domainSuffix, value: "example.com", target: ""),
                    RoutingRule(type: .port, value: "443", target: ""),
                ], target: "proxy"),
            ]
        )
        let config = try buildJSON(nodes: [ssNode("A")], routing: routing)
        let rules = try rules(in: config)
        XCTAssertEqual(rules.count, 1)
        let logical = rules[0]
        XCTAssertEqual(logical["type"] as? String, "logical")
        XCTAssertEqual(logical["mode"] as? String, "and")
        XCTAssertEqual(logical["action"] as? String, "route")
        XCTAssertEqual(logical["outbound"] as? String, "proxy")
        let sub = try XCTUnwrap(logical["rules"] as? [[String: Any]])
        XCTAssertEqual(sub.count, 2)
        XCTAssertEqual(sub[0]["domain_suffix"] as? [String], ["example.com"])
        XCTAssertEqual(sub[1]["port"] as? [Int], [443])
        // Sub-rules carry no action.
        XCTAssertNil(sub[0]["action"])
    }

    func testLogicalNotRuleInverts() throws {
        let routing = RoutingConfig(
            rules: [
                RoutingRule(type: .not, subRules: [
                    RoutingRule(type: .geosite, value: "geosite-cn", target: ""),
                ], target: "proxy"),
            ],
            ruleSets: [RuleSetEntry(tag: "geosite-cn", url: "https://e/x.srs")]
        )
        let config = try buildJSON(nodes: [ssNode("A")], routing: routing)
        let logical = try rules(in: config)[0]
        XCTAssertEqual(logical["type"] as? String, "logical")
        XCTAssertEqual(logical["mode"] as? String, "and")
        XCTAssertEqual(logical["invert"] as? Bool, true)
    }

    // MARK: - urltest group (golden)

    func testURLTestGroup() throws {
        let routing = RoutingConfig(
            groups: [
                PolicyGroup(name: "proxy", type: .select,
                            members: [.group("Auto"), .builtin("direct")], isDefault: true),
                PolicyGroup(name: "Auto", type: .urlTest,
                            members: [.node("A"), .node("B")],
                            testURL: "http://www.gstatic.com/generate_204",
                            interval: "5m", tolerance: 100),
            ],
            finalTarget: "proxy"
        )
        let config = try buildJSON(nodes: [ssNode("A"), ssNode("B")], routing: routing)

        let auto = try outbound(tagged: "Auto", in: config)
        XCTAssertEqual(auto["type"] as? String, "urltest")
        XCTAssertEqual(auto["outbounds"] as? [String], ["A", "B"])
        XCTAssertEqual(auto["url"] as? String, "http://www.gstatic.com/generate_204")
        XCTAssertEqual(auto["interval"] as? String, "5m")
        XCTAssertEqual(auto["tolerance"] as? Int, 100)

        let proxy = try outbound(tagged: "proxy", in: config)
        XCTAssertEqual(proxy["type"] as? String, "selector")
        XCTAssertEqual(proxy["outbounds"] as? [String], ["Auto", "direct"])
    }

    func testURLTestGroupUsesDefaultsWhenUnset() throws {
        let routing = RoutingConfig(
            groups: [
                PolicyGroup(name: "Auto", type: .urlTest, members: [.node("A")]),
            ]
        )
        let config = try buildJSON(nodes: [ssNode("A")], routing: routing)
        let auto = try outbound(tagged: "Auto", in: config)
        XCTAssertEqual(auto["url"] as? String, "https://www.gstatic.com/generate_204")
        XCTAssertEqual(auto["interval"] as? String, "3m")
        XCTAssertNil(auto["tolerance"])
    }

    func testFallbackAndLoadBalanceDegradeToURLTest() throws {
        let routing = RoutingConfig(
            groups: [
                PolicyGroup(name: "FB", type: .fallback, members: [.node("A")]),
                PolicyGroup(name: "LB", type: .loadBalance, members: [.node("A")]),
            ]
        )
        let config = try buildJSON(nodes: [ssNode("A")], routing: routing)
        XCTAssertEqual(try outbound(tagged: "FB", in: config)["type"] as? String, "urltest")
        XCTAssertEqual(try outbound(tagged: "LB", in: config)["type"] as? String, "urltest")

        let warnings = try builder.validate(nodes: [ssNode("A")], routing: routing)
        // validate() does not flag degradation (that surfaces during build), but
        // must not produce false target errors for valid groups.
        XCTAssertFalse(warnings.contains { $0.contains("未找到") })
    }

    // MARK: - Nested group (golden)

    func testNestedGroup() throws {
        let routing = RoutingConfig(
            groups: [
                PolicyGroup(name: "proxy", type: .select,
                            members: [.group("Region"), .builtin("direct")], isDefault: true),
                PolicyGroup(name: "Region", type: .select,
                            members: [.group("HK"), .group("US")]),
                PolicyGroup(name: "HK", type: .urlTest, members: [.node("hk1"), .node("hk2")]),
                PolicyGroup(name: "US", type: .select, members: [.node("us1")]),
            ],
            finalTarget: "proxy"
        )
        let nodes = [ssNode("hk1"), ssNode("hk2"), ssNode("us1")]
        let config = try buildJSON(nodes: nodes, routing: routing)

        let region = try outbound(tagged: "Region", in: config)
        XCTAssertEqual(region["type"] as? String, "selector")
        XCTAssertEqual(region["outbounds"] as? [String], ["HK", "US"])

        let hk = try outbound(tagged: "HK", in: config)
        XCTAssertEqual(hk["type"] as? String, "urltest")
        XCTAssertEqual(hk["outbounds"] as? [String], ["hk1", "hk2"])

        let proxy = try outbound(tagged: "proxy", in: config)
        XCTAssertEqual(proxy["outbounds"] as? [String], ["Region", "direct"])

        // No legacy selector synthesized when user groups exist; "proxy" is the
        // user-defined one.
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.filter { $0["tag"] as? String == "proxy" }.count, 1)
    }

    func testGroupCycleDetectedByValidate() throws {
        let routing = RoutingConfig(
            groups: [
                PolicyGroup(name: "A", type: .select, members: [.group("B")]),
                PolicyGroup(name: "B", type: .select, members: [.group("A")]),
            ]
        )
        let warnings = try builder.validate(nodes: [ssNode("x")], routing: routing)
        XCTAssertTrue(warnings.contains { $0.contains("循环引用") }, "\(warnings)")
    }

    // MARK: - DNS block (golden)

    func testDNSBlock() throws {
        let routing = RoutingConfig(
            ruleSets: [RuleSetEntry(tag: "geosite-cn", url: "https://e/cn.srs")],
            dns: DNSConfig(
                isEnabled: true,
                servers: [
                    DNSServer(tag: "dns-domestic", address: "https://223.5.5.5/dns-query", detour: "direct"),
                    DNSServer(tag: "dns-proxy", address: "tls://1.1.1.1", detour: "proxy"),
                ],
                rules: [
                    DNSRule(matcher: .ruleSet, value: "geosite-cn", server: "dns-domestic"),
                    DNSRule(matcher: .domainSuffix, value: "google.com,youtube.com", server: "dns-proxy"),
                ],
                finalServerTag: "dns-proxy",
                strategy: .preferIPv4
            )
        )
        let config = try buildJSON(nodes: [ssNode("A")], routing: routing)
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])

        // Modern (1.12+) typed-server format. A bootstrap "local" server is
        // injected ahead of the user servers, so there are 3 total.
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.count, 3)
        XCTAssertEqual(servers[0]["type"] as? String, "local")
        XCTAssertEqual(servers[0]["tag"] as? String, "dns-local")

        let domestic = try XCTUnwrap(servers.first { $0["tag"] as? String == "dns-domestic" })
        XCTAssertEqual(domestic["type"] as? String, "https")
        XCTAssertEqual(domestic["server"] as? String, "223.5.5.5")
        XCTAssertEqual(domestic["path"] as? String, "/dns-query")
        XCTAssertEqual(domestic["detour"] as? String, "direct")
        // An IP-literal server needs no domain_resolver.
        XCTAssertNil(domestic["domain_resolver"])

        let proxyServer = try XCTUnwrap(servers.first { $0["tag"] as? String == "dns-proxy" })
        XCTAssertEqual(proxyServer["type"] as? String, "tls")
        XCTAssertEqual(proxyServer["server"] as? String, "1.1.1.1")

        // DNS rules carry the explicit route action (1.12+).
        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertEqual(dnsRules.count, 2)
        XCTAssertEqual(dnsRules[0]["action"] as? String, "route")
        XCTAssertEqual(dnsRules[0]["rule_set"] as? [String], ["geosite-cn"])
        XCTAssertEqual(dnsRules[0]["server"] as? String, "dns-domestic")
        XCTAssertEqual(dnsRules[1]["domain_suffix"] as? [String], ["google.com", "youtube.com"])
        XCTAssertEqual(dnsRules[1]["server"] as? String, "dns-proxy")

        XCTAssertEqual(dns["final"] as? String, "dns-proxy")
        XCTAssertEqual(dns["strategy"] as? String, "prefer_ipv4")
        XCTAssertNil(dns["fakeip"])

        // The route layer must wire default_domain_resolver to the bootstrap
        // server, or sing-box 1.13 fatally refuses to start with DNS configured.
        let route = try XCTUnwrap(config["route"] as? [String: Any])
        let resolver = try XCTUnwrap(route["default_domain_resolver"] as? [String: Any])
        XCTAssertEqual(resolver["server"] as? String, "dns-local")
    }

    func testDNSBlockOmittedWhenDisabled() throws {
        let config = try buildJSON(nodes: [ssNode("A")], routing: .empty)
        XCTAssertNil(config["dns"])
    }

    func testFakeIPEmittedOnlyWhenEnabled() throws {
        let routing = RoutingConfig(
            dns: DNSConfig(
                isEnabled: true,
                servers: [DNSServer(tag: "fake", address: "fakeip")],
                fakeIP: FakeIPConfig(enabled: true)
            )
        )
        let config = try buildJSON(nodes: [ssNode("A")], routing: routing)
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        // In the 1.12+ format fakeip is a typed server entry, not a top-level block.
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let fakeip = try XCTUnwrap(servers.first { $0["type"] as? String == "fakeip" })
        XCTAssertEqual(fakeip["tag"] as? String, "fake")
        XCTAssertEqual(fakeip["inet4_range"] as? String, "198.18.0.0/15")
        XCTAssertEqual(fakeip["inet6_range"] as? String, "fc00::/18")
        XCTAssertNil(dns["fakeip"])
    }

    // MARK: - Transport / TLS / Reality / plugin outbounds (golden)

    func testVMessWSTLSNode() throws {
        let node = ProxyNode(
            name: "VM", protocolType: .vmess, server: "vm.example.com", port: 443,
            uuid: "11111111-2222-3333-4444-555555555555", alterId: 0,
            tls: TLSOptions(enabled: true, serverName: "cdn.example.com",
                            alpn: ["h2", "http/1.1"], utlsFingerprint: .chrome),
            transport: TransportOptions(type: .ws, path: "/ray", host: ["cdn.example.com"])
        )
        let config = try buildJSON(nodes: [node], routing: .empty)
        let outbound = try outbound(tagged: "VM", in: config)

        let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
        XCTAssertEqual(tls["enabled"] as? Bool, true)
        XCTAssertEqual(tls["server_name"] as? String, "cdn.example.com")
        XCTAssertEqual(tls["alpn"] as? [String], ["h2", "http/1.1"])
        let utls = try XCTUnwrap(tls["utls"] as? [String: Any])
        XCTAssertEqual(utls["enabled"] as? Bool, true)
        XCTAssertEqual(utls["fingerprint"] as? String, "chrome")

        let transport = try XCTUnwrap(outbound["transport"] as? [String: Any])
        XCTAssertEqual(transport["type"] as? String, "ws")
        XCTAssertEqual(transport["path"] as? String, "/ray")
        let headers = try XCTUnwrap(transport["headers"] as? [String: String])
        XCTAssertEqual(headers["Host"], "cdn.example.com")
    }

    func testVLESSRealityNode() throws {
        let node = ProxyNode(
            name: "VL", protocolType: .vless, server: "vl.example.com", port: 443,
            uuid: "u", flow: "xtls-rprx-vision",
            tls: TLSOptions(
                enabled: true, serverName: "www.microsoft.com",
                utlsFingerprint: .chrome,
                reality: RealityOptions(enabled: true,
                                        publicKey: "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0",
                                        shortID: "0123abcd")
            ),
            transport: TransportOptions(type: .grpc, serviceName: "grpcSvc")
        )
        let config = try buildJSON(nodes: [node], routing: .empty)
        let outbound = try outbound(tagged: "VL", in: config)

        XCTAssertEqual(outbound["flow"] as? String, "xtls-rprx-vision")
        let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
        let reality = try XCTUnwrap(tls["reality"] as? [String: Any])
        XCTAssertEqual(reality["enabled"] as? Bool, true)
        XCTAssertEqual(reality["public_key"] as? String, "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0")
        XCTAssertEqual(reality["short_id"] as? String, "0123abcd")

        let transport = try XCTUnwrap(outbound["transport"] as? [String: Any])
        XCTAssertEqual(transport["type"] as? String, "grpc")
        XCTAssertEqual(transport["service_name"] as? String, "grpcSvc")
    }

    func testShadowsocksObfsPluginNode() throws {
        let node = ProxyNode(
            name: "SS", protocolType: .shadowsocks, server: "ss.example.com", port: 8388,
            password: "pw", method: "aes-256-gcm",
            plugin: "obfs-local", pluginOpts: "obfs=http;obfs-host=www.bing.com"
        )
        let config = try buildJSON(nodes: [node], routing: .empty)
        let outbound = try outbound(tagged: "SS", in: config)
        XCTAssertEqual(outbound["type"] as? String, "shadowsocks")
        XCTAssertEqual(outbound["plugin"] as? String, "obfs-local")
        XCTAssertEqual(outbound["plugin_opts"] as? String, "obfs=http;obfs-host=www.bing.com")
        XCTAssertNil(outbound["tls"])
    }

    func testHTTPTransportHostIsArray() throws {
        let node = ProxyNode(
            name: "VM", protocolType: .vmess, server: "h.example.com", port: 443,
            uuid: "u", tlsEnabled: true,
            transport: TransportOptions(type: .http, path: "/v2", host: ["a.com", "b.com"])
        )
        let config = try buildJSON(nodes: [node], routing: .empty)
        let transport = try XCTUnwrap(try outbound(tagged: "VM", in: config)["transport"] as? [String: Any])
        XCTAssertEqual(transport["type"] as? String, "http")
        XCTAssertEqual(transport["host"] as? [String], ["a.com", "b.com"])
        XCTAssertEqual(transport["path"] as? String, "/v2")
    }

    func testHTTPUpgradeTransportHostIsString() throws {
        let node = ProxyNode(
            name: "VM", protocolType: .vmess, server: "h.example.com", port: 443,
            uuid: "u", tlsEnabled: true,
            transport: TransportOptions(type: .httpUpgrade, path: "/up", host: ["edge.com"])
        )
        let config = try buildJSON(nodes: [node], routing: .empty)
        let transport = try XCTUnwrap(try outbound(tagged: "VM", in: config)["transport"] as? [String: Any])
        XCTAssertEqual(transport["type"] as? String, "httpupgrade")
        XCTAssertEqual(transport["host"] as? String, "edge.com")
        XCTAssertEqual(transport["path"] as? String, "/up")
    }

    // MARK: - validate()

    func testValidateFlagsUnknownRuleTarget() throws {
        let routing = RoutingConfig(
            rules: [RoutingRule(type: .domain, value: "x.com", target: "Nope")]
        )
        let warnings = try builder.validate(nodes: [ssNode("A")], routing: routing)
        XCTAssertTrue(warnings.contains { $0.contains("Nope") }, "\(warnings)")
    }

    func testValidateFlagsUnknownRuleSet() throws {
        let routing = RoutingConfig(
            rules: [RoutingRule(type: .geosite, value: "ghost-set", target: "proxy")]
        )
        let warnings = try builder.validate(nodes: [ssNode("A")], routing: routing)
        XCTAssertTrue(warnings.contains { $0.contains("ghost-set") }, "\(warnings)")
    }

    func testValidateAcceptsValidConfig() throws {
        let routing = RoutingConfig(
            rules: [RoutingRule(type: .domainSuffix, value: "google.com", target: "proxy")],
            groups: [PolicyGroup(name: "proxy", members: [.node("A"), .builtin("direct")], isDefault: true)],
            finalTarget: "proxy"
        )
        let warnings = try builder.validate(nodes: [ssNode("A")], routing: routing)
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    // MARK: - Unknown target dropped during build

    func testUnknownRuleTargetDroppedFromBuild() throws {
        let routing = RoutingConfig(
            rules: [
                RoutingRule(type: .domain, value: "x.com", target: "Nope"),
                RoutingRule(type: .domain, value: "y.com", target: "proxy"),
            ]
        )
        let config = try buildJSON(nodes: [ssNode("A")], routing: routing)
        let rules = try rules(in: config)
        // Only the valid rule survives.
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["domain"] as? [String], ["y.com"])
    }

    func testUnknownFinalFallsBackToProxy() throws {
        let routing = RoutingConfig(finalTarget: "Ghost")
        let config = try buildJSON(nodes: [ssNode("A")], routing: routing)
        XCTAssertEqual(try route(in: config)["final"] as? String, "proxy")
    }

    // MARK: - Backward compatibility

    func testEmptyRoutingMatchesLegacyShape() throws {
        let config = try buildJSON(nodes: [ssNode("A"), ssNode("B")], routing: .empty)
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        // selector "proxy" + 2 nodes + direct
        XCTAssertEqual(outbounds.count, 4)
        let proxy = try outbound(tagged: "proxy", in: config)
        XCTAssertEqual(proxy["type"] as? String, "selector")
        XCTAssertEqual(proxy["outbounds"] as? [String], ["A", "B", "direct"])
        XCTAssertEqual(try route(in: config)["final"] as? String, "proxy")
        XCTAssertNil(config["dns"])
    }
}
