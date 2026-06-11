import XCTest
@testable import LinkoKit

final class SingBoxConfigBuilderTests: XCTestCase {
    private let builder = SingBoxConfigBuilder()

    private func buildJSON(
        nodes: [ProxyNode],
        preferences: AppPreferences = AppPreferences()
    ) throws -> [String: Any] {
        let data = try builder.build(nodes: nodes, preferences: preferences)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func outbound(tagged tag: String, in config: [String: Any]) throws -> [String: Any] {
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        return try XCTUnwrap(
            outbounds.first { $0["tag"] as? String == tag },
            "no outbound tagged \(tag)"
        )
    }

    // MARK: - Top-level shape

    func testTopLevelShape() throws {
        let prefs = AppPreferences(mixedPort: 7777, clashAPIPort: 9999)
        let node = ProxyNode(
            name: "HK", protocolType: .shadowsocks, server: "hk.example.com", port: 8388,
            password: "pw", method: "aes-256-gcm"
        )
        let config = try buildJSON(nodes: [node], preferences: prefs)

        let inbounds = try XCTUnwrap(config["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.count, 1)
        XCTAssertEqual(inbounds[0]["type"] as? String, "mixed")
        XCTAssertEqual(inbounds[0]["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(inbounds[0]["listen_port"] as? Int, 7777)

        let route = try XCTUnwrap(config["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "proxy")

        let experimental = try XCTUnwrap(config["experimental"] as? [String: Any])
        let clashAPI = try XCTUnwrap(experimental["clash_api"] as? [String: Any])
        XCTAssertEqual(clashAPI["external_controller"] as? String, "127.0.0.1:9999")

        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        // selector + 1 node + direct
        XCTAssertEqual(outbounds.count, 3)
        XCTAssertEqual(outbounds.first?["type"] as? String, "selector")
        XCTAssertEqual(outbounds.last?["type"] as? String, "direct")
        XCTAssertEqual(outbounds.last?["tag"] as? String, "direct")
    }

    func testSelectorContainsAllNodeTagsPlusDirect() throws {
        let nodes = [
            ProxyNode(name: "A", protocolType: .shadowsocks, server: "a.example.com", port: 1,
                      password: "p", method: "aes-128-gcm"),
            ProxyNode(name: "B", protocolType: .trojan, server: "b.example.com", port: 2,
                      password: "p"),
        ]
        let config = try buildJSON(nodes: nodes)
        let selector = try outbound(tagged: "proxy", in: config)
        XCTAssertEqual(selector["type"] as? String, "selector")
        XCTAssertEqual(selector["outbounds"] as? [String], ["A", "B", "direct"])
    }

    func testSelectorDefaultTracksSelectedNode() throws {
        let selected = ProxyNode(
            name: "B", protocolType: .trojan, server: "b.example.com", port: 443, password: "p"
        )
        let nodes = [
            ProxyNode(name: "A", protocolType: .shadowsocks, server: "a.example.com", port: 1,
                      password: "p", method: "aes-128-gcm"),
            selected,
        ]
        var prefs = AppPreferences()
        prefs.selectedNodeID = selected.id
        let config = try buildJSON(nodes: nodes, preferences: prefs)
        let selector = try outbound(tagged: "proxy", in: config)
        XCTAssertEqual(selector["default"] as? String, "B")
    }

    // MARK: - Per-protocol outbounds

    func testShadowsocksOutbound() throws {
        let node = ProxyNode(
            name: "SS", protocolType: .shadowsocks, server: "ss.example.com", port: 8388,
            password: "pw", method: "chacha20-ietf-poly1305"
        )
        let config = try buildJSON(nodes: [node])
        let outbound = try outbound(tagged: "SS", in: config)
        XCTAssertEqual(outbound["type"] as? String, "shadowsocks")
        XCTAssertEqual(outbound["server"] as? String, "ss.example.com")
        XCTAssertEqual(outbound["server_port"] as? Int, 8388)
        XCTAssertEqual(outbound["method"] as? String, "chacha20-ietf-poly1305")
        XCTAssertEqual(outbound["password"] as? String, "pw")
        XCTAssertNil(outbound["tls"])
    }

    func testVMessOutboundWithTLS() throws {
        let node = ProxyNode(
            name: "VM", protocolType: .vmess, server: "vm.example.com", port: 443,
            uuid: "11111111-2222-3333-4444-555555555555", alterId: 4,
            tlsEnabled: true, sni: "cdn.example.com", allowInsecure: true
        )
        let config = try buildJSON(nodes: [node])
        let outbound = try outbound(tagged: "VM", in: config)
        XCTAssertEqual(outbound["type"] as? String, "vmess")
        XCTAssertEqual(outbound["uuid"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(outbound["security"] as? String, "auto")
        XCTAssertEqual(outbound["alter_id"] as? Int, 4)
        let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
        XCTAssertEqual(tls["enabled"] as? Bool, true)
        XCTAssertEqual(tls["server_name"] as? String, "cdn.example.com")
        XCTAssertEqual(tls["insecure"] as? Bool, true)
    }

    func testVMessOutboundWithoutTLSDefaultsAlterIDToZero() throws {
        let node = ProxyNode(
            name: "VM", protocolType: .vmess, server: "vm.example.com", port: 80,
            uuid: "u"
        )
        let config = try buildJSON(nodes: [node])
        let outbound = try outbound(tagged: "VM", in: config)
        XCTAssertEqual(outbound["alter_id"] as? Int, 0)
        XCTAssertNil(outbound["tls"])
    }

    func testVLESSOutboundWithFlow() throws {
        let node = ProxyNode(
            name: "VL", protocolType: .vless, server: "vl.example.com", port: 443,
            uuid: "u", flow: "xtls-rprx-vision", tlsEnabled: true, sni: "vl.example.com"
        )
        let config = try buildJSON(nodes: [node])
        let outbound = try outbound(tagged: "VL", in: config)
        XCTAssertEqual(outbound["type"] as? String, "vless")
        XCTAssertEqual(outbound["uuid"] as? String, "u")
        XCTAssertEqual(outbound["flow"] as? String, "xtls-rprx-vision")
        let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
        XCTAssertEqual(tls["enabled"] as? Bool, true)
        XCTAssertEqual(tls["server_name"] as? String, "vl.example.com")
        XCTAssertNil(tls["insecure"])
    }

    func testTrojanOutboundAlwaysHasTLS() throws {
        let node = ProxyNode(
            name: "TJ", protocolType: .trojan, server: "tj.example.com", port: 443,
            password: "pw", tlsEnabled: false
        )
        let config = try buildJSON(nodes: [node])
        let outbound = try outbound(tagged: "TJ", in: config)
        XCTAssertEqual(outbound["type"] as? String, "trojan")
        XCTAssertEqual(outbound["password"] as? String, "pw")
        let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
        XCTAssertEqual(tls["enabled"] as? Bool, true)
    }

    func testHysteria2Outbound() throws {
        let node = ProxyNode(
            name: "HY", protocolType: .hysteria2, server: "hy.example.com", port: 443,
            password: "pw", sni: "hy.example.com", allowInsecure: true
        )
        let config = try buildJSON(nodes: [node])
        let outbound = try outbound(tagged: "HY", in: config)
        XCTAssertEqual(outbound["type"] as? String, "hysteria2")
        XCTAssertEqual(outbound["password"] as? String, "pw")
        let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
        XCTAssertEqual(tls["enabled"] as? Bool, true)
        XCTAssertEqual(tls["insecure"] as? Bool, true)
    }

    func testTUICOutbound() throws {
        let node = ProxyNode(
            name: "TU", protocolType: .tuic, server: "tu.example.com", port: 443,
            password: "pw", uuid: "u", sni: "tu.example.com"
        )
        let config = try buildJSON(nodes: [node])
        let outbound = try outbound(tagged: "TU", in: config)
        XCTAssertEqual(outbound["type"] as? String, "tuic")
        XCTAssertEqual(outbound["uuid"] as? String, "u")
        XCTAssertEqual(outbound["password"] as? String, "pw")
        let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
        XCTAssertEqual(tls["enabled"] as? Bool, true)
    }

    // MARK: - Errors and edge cases

    func testEmptyNodesThrows() {
        XCTAssertThrowsError(try builder.build(nodes: [], preferences: AppPreferences())) { error in
            XCTAssertEqual(error as? SingBoxConfigError, .noNodes)
        }
    }

    func testMissingRequiredFieldThrows() {
        let node = ProxyNode(name: "SS", protocolType: .shadowsocks, server: "s", port: 1)
        XCTAssertThrowsError(try builder.build(nodes: [node], preferences: AppPreferences())) { error in
            XCTAssertEqual(error as? SingBoxConfigError, .missingField(node: "SS", field: "method"))
        }
    }

    func testDuplicateAndReservedNamesAreDeduplicated() throws {
        let nodes = [
            ProxyNode(name: "direct", protocolType: .trojan, server: "a", port: 1, password: "p"),
            ProxyNode(name: "N", protocolType: .trojan, server: "b", port: 2, password: "p"),
            ProxyNode(name: "N", protocolType: .trojan, server: "c", port: 3, password: "p"),
        ]
        let config = try buildJSON(nodes: nodes)
        let selector = try outbound(tagged: "proxy", in: config)
        XCTAssertEqual(selector["outbounds"] as? [String], ["direct-2", "N", "N-2", "direct"])
    }

    func testOutboundTagsMatchBuiltConfigTags() throws {
        // Runtime Clash API calls (select/delay) must address nodes by the
        // exact tags the built config uses, even with duplicate names.
        let nodes = [
            ProxyNode(name: "direct", protocolType: .trojan, server: "a", port: 1, password: "p"),
            ProxyNode(name: "N", protocolType: .trojan, server: "b", port: 2, password: "p"),
            ProxyNode(name: "N", protocolType: .trojan, server: "c", port: 3, password: "p"),
        ]
        let tags = builder.outboundTags(for: nodes)
        XCTAssertEqual(tags, ["direct-2", "N", "N-2"])

        let config = try buildJSON(nodes: nodes)
        let selector = try outbound(tagged: "proxy", in: config)
        XCTAssertEqual(selector["outbounds"] as? [String], tags + ["direct"])

        // The second "N" must map to the outbound for server "c".
        let secondN = try outbound(tagged: tags[2], in: config)
        XCTAssertEqual(secondN["server"] as? String, "c")
    }

    func testSelectorDefaultUsesDedupedTagForDuplicateName() throws {
        let first = ProxyNode(name: "N", protocolType: .trojan, server: "b", port: 2, password: "p")
        let second = ProxyNode(name: "N", protocolType: .trojan, server: "c", port: 3, password: "p")
        var prefs = AppPreferences()
        prefs.selectedNodeID = second.id
        let config = try buildJSON(nodes: [first, second], preferences: prefs)
        let selector = try outbound(tagged: "proxy", in: config)
        XCTAssertEqual(selector["default"] as? String, "N-2")
    }

    func testOutputIsValidUTF8JSON() throws {
        let node = ProxyNode(
            name: "HK", protocolType: .shadowsocks, server: "s", port: 1,
            password: "p", method: "m"
        )
        let data = try builder.build(nodes: [node], preferences: AppPreferences())
        XCTAssertNotNil(String(data: data, encoding: .utf8))
    }

    // MARK: - TUN DNS guarantees

    private func tunPrefs() -> AppPreferences {
        var prefs = AppPreferences()
        prefs.proxyMode = .tun
        return prefs
    }

    private var sampleNode: ProxyNode {
        ProxyNode(
            name: "HK", protocolType: .shadowsocks, server: "hk.example.com", port: 8388,
            password: "pw", method: "aes-256-gcm"
        )
    }

    func testTunModeSynthesizesFallbackDNSWhenDisabled() throws {
        let config = try buildJSON(nodes: [sampleNode], preferences: tunPrefs())

        let dns = try XCTUnwrap(config["dns"] as? [String: Any], "tun config must carry a dns block")
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let fallback = try XCTUnwrap(servers.first { ($0["tag"] as? String) == SingBoxConfigBuilder.tunFallbackDNSTag })
        XCTAssertEqual(fallback["type"] as? String, "udp")
        XCTAssertEqual(fallback["detour"] as? String, "direct")

        let route = try XCTUnwrap(config["route"] as? [String: Any])
        let resolver = try XCTUnwrap(route["default_domain_resolver"] as? [String: Any])
        XCTAssertEqual(resolver["server"] as? String, SingBoxConfigBuilder.tunFallbackDNSTag)
    }

    func testTunModePrefixesSniffAndHijackRules() throws {
        let config = try buildJSON(nodes: [sampleNode], preferences: tunPrefs())
        let route = try XCTUnwrap(config["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rules.count, 2)
        XCTAssertEqual(rules[0]["action"] as? String, "sniff")
        XCTAssertEqual(rules[1]["action"] as? String, "hijack-dns")
        XCTAssertEqual(rules[1]["protocol"] as? String, "dns")
    }

    func testTunModeKeepsUserDNSWhenEnabled() throws {
        var prefs = tunPrefs()
        prefs.routing.dns.isEnabled = true
        prefs.routing.dns.servers = [
            DNSServer(tag: "user-doh", address: "https://1.1.1.1/dns-query")
        ]
        let config = try buildJSON(nodes: [sampleNode], preferences: prefs)

        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        XCTAssertTrue(servers.contains { ($0["tag"] as? String) == "user-doh" })
        XCTAssertFalse(
            servers.contains { ($0["tag"] as? String) == SingBoxConfigBuilder.tunFallbackDNSTag },
            "user DNS present: no fallback server should be synthesized"
        )
        // The hijack prefix still applies regardless of who provided DNS.
        let route = try XCTUnwrap(config["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules[0]["action"] as? String, "sniff")
        XCTAssertEqual(rules[1]["action"] as? String, "hijack-dns")
    }

    func testSystemProxyModeStaysDNSFree() throws {
        let config = try buildJSON(nodes: [sampleNode], preferences: AppPreferences())
        XCTAssertNil(config["dns"], "system-proxy mode must not grow a dns block")
        let route = try XCTUnwrap(config["route"] as? [String: Any])
        let rules = (route["rules"] as? [[String: Any]]) ?? []
        XCTAssertFalse(rules.contains { ($0["action"] as? String) == "hijack-dns" })
    }
}
