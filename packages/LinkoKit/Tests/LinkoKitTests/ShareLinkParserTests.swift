import XCTest
@testable import LinkoKit

/// Covers the `scheme://…` share-link parsers and the format-detecting
/// `SubscriptionParser.parse(subscription:)` entry point.
final class ShareLinkParserTests: XCTestCase {
    private let links = ShareLinkParser()
    private let subscriptions = SubscriptionParser()

    // MARK: - shadowsocks

    func testShadowsocksSIP002() throws {
        let userinfo = Data("aes-128-gcm:secret".utf8).base64EncodedString()
        let node = try links.node(fromShareLink: "ss://\(userinfo)@1.2.3.4:8888#HK%20Node")
        XCTAssertEqual(node.protocolType, .shadowsocks)
        XCTAssertEqual(node.server, "1.2.3.4")
        XCTAssertEqual(node.port, 8888)
        XCTAssertEqual(node.method, "aes-128-gcm")
        XCTAssertEqual(node.password, "secret")
        XCTAssertEqual(node.name, "HK Node")
    }

    func testShadowsocksLegacyBase64() throws {
        let blob = Data("aes-256-gcm:pw@1.1.1.1:1234".utf8).base64EncodedString()
        let node = try links.node(fromShareLink: "ss://\(blob)#Legacy")
        XCTAssertEqual(node.method, "aes-256-gcm")
        XCTAssertEqual(node.password, "pw")
        XCTAssertEqual(node.server, "1.1.1.1")
        XCTAssertEqual(node.port, 1234)
        XCTAssertEqual(node.name, "Legacy")
    }

    func testShadowsocksPlugin() throws {
        let userinfo = Data("chacha20-ietf-poly1305:p".utf8).base64EncodedString()
        let link = "ss://\(userinfo)@host.example:443?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dbing.com#SS"
        let node = try links.node(fromShareLink: link)
        XCTAssertEqual(node.plugin, "obfs-local")
        XCTAssertEqual(node.pluginOpts, "obfs=http;obfs-host=bing.com")
    }

    // MARK: - vmess

    func testVMessV2RayN() throws {
        let json = """
        {"v":"2","ps":"VM Node","add":"v.example.com","port":"443","id":"uuid-1",\
        "aid":"0","net":"ws","host":"h.example.com","path":"/ray","tls":"tls","sni":"s.example.com"}
        """
        let node = try links.node(fromShareLink: "vmess://\(Data(json.utf8).base64EncodedString())")
        XCTAssertEqual(node.protocolType, .vmess)
        XCTAssertEqual(node.server, "v.example.com")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.uuid, "uuid-1")
        XCTAssertEqual(node.name, "VM Node")
        XCTAssertTrue(node.tls.enabled)
        XCTAssertEqual(node.sni, "s.example.com")
        XCTAssertEqual(node.transport.type, .ws)
        XCTAssertEqual(node.transport.path, "/ray")
        XCTAssertEqual(node.transport.host, ["h.example.com"])
    }

    // MARK: - vless (REALITY + flow)

    func testVLESSReality() throws {
        let link = "vless://uuid-2@v2.example.com:443?security=reality&sni=www.apple.com" +
            "&pbk=PUBKEY&sid=abcd&type=tcp&flow=xtls-rprx-vision&fp=chrome#VL"
        let node = try links.node(fromShareLink: link)
        XCTAssertEqual(node.protocolType, .vless)
        XCTAssertEqual(node.uuid, "uuid-2")
        XCTAssertEqual(node.port, 443)
        XCTAssertTrue(node.tls.enabled)
        XCTAssertEqual(node.tls.reality?.publicKey, "PUBKEY")
        XCTAssertEqual(node.tls.reality?.shortID, "abcd")
        XCTAssertEqual(node.flow, "xtls-rprx-vision")
        XCTAssertEqual(node.tls.utlsFingerprint, .chrome)
    }

    // MARK: - trojan

    func testTrojanWebSocket() throws {
        let link = "trojan://pass123@t.example.com:443?sni=t.sni.com&type=ws&host=t.host.com&path=%2Ftj#TJ"
        let node = try links.node(fromShareLink: link)
        XCTAssertEqual(node.protocolType, .trojan)
        XCTAssertEqual(node.password, "pass123")
        XCTAssertTrue(node.tls.enabled)
        XCTAssertEqual(node.sni, "t.sni.com")
        XCTAssertEqual(node.transport.type, .ws)
        XCTAssertEqual(node.transport.path, "/tj")
        XCTAssertEqual(node.transport.host, ["t.host.com"])
    }

    // MARK: - hysteria2

    func testHysteria2WithObfs() throws {
        let link = "hysteria2://pw@h.example.com:8443?sni=h.sni.com&insecure=1&obfs=salamander&obfs-password=ob#HY"
        let node = try links.node(fromShareLink: link)
        XCTAssertEqual(node.protocolType, .hysteria2)
        XCTAssertEqual(node.password, "pw")
        XCTAssertEqual(node.port, 8443)
        XCTAssertTrue(node.tls.enabled)
        XCTAssertTrue(node.tls.insecure)
        XCTAssertEqual(node.sni, "h.sni.com")
        let opts = node.pluginOpts ?? ""
        XCTAssertTrue(opts.contains("obfs=salamander"), opts)
        XCTAssertTrue(opts.contains("obfs-password=ob"), opts)
    }

    func testHy2Alias() throws {
        let node = try links.node(fromShareLink: "hy2://pw2@h2.example.com:443?sni=x#HY2")
        XCTAssertEqual(node.protocolType, .hysteria2)
        XCTAssertEqual(node.password, "pw2")
    }

    // MARK: - tuic

    func testTUIC() throws {
        let link = "tuic://uuid-3:tpw@tu.example.com:443?sni=tu.sni.com" +
            "&congestion_control=bbr&udp_relay_mode=native&alpn=h3#TU"
        let node = try links.node(fromShareLink: link)
        XCTAssertEqual(node.protocolType, .tuic)
        XCTAssertEqual(node.uuid, "uuid-3")
        XCTAssertEqual(node.password, "tpw")
        XCTAssertEqual(node.sni, "tu.sni.com")
        XCTAssertEqual(node.tls.alpn, ["h3"])
        let opts = node.pluginOpts ?? ""
        XCTAssertTrue(opts.contains("congestion-control=bbr"), opts)
        XCTAssertTrue(opts.contains("udp-relay-mode=native"), opts)
    }

    // MARK: - Bulk + warnings

    func testUnsupportedSchemeIsSkippedWithWarning() {
        let userinfo = Data("aes-128-gcm:s".utf8).base64EncodedString()
        let text = """
        ssr://unsupported-payload
        ss://\(userinfo)@9.9.9.9:443#Good
        """
        let result = links.parseLinks(text)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.name, "Good")
        XCTAssertEqual(result.warnings.count, 1)
    }

    // MARK: - Format detection

    func testDetectsPlainShareLinks() throws {
        let userinfo = Data("aes-128-gcm:s".utf8).base64EncodedString()
        let text = "ss://\(userinfo)@1.1.1.1:443#A\ntrojan://pw@b.com:443#B"
        let result = try subscriptions.parse(subscription: text)
        XCTAssertEqual(result.format, .shareLinks)
        XCTAssertEqual(result.nodes.count, 2)
    }

    func testDetectsBase64Subscription() throws {
        let userinfo = Data("aes-128-gcm:s".utf8).base64EncodedString()
        let inner = "ss://\(userinfo)@1.1.1.1:443#A\ntrojan://pw@b.com:443#B"
        let blob = Data(inner.utf8).base64EncodedString()
        let result = try subscriptions.parse(subscription: blob)
        XCTAssertEqual(result.format, .base64Links)
        XCTAssertEqual(result.nodes.count, 2)
    }

    func testDetectsClashYAML() throws {
        let yaml = """
        proxies:
          - name: C
            type: ss
            server: 2.2.2.2
            port: 8388
            cipher: aes-128-gcm
            password: p
        """
        let result = try subscriptions.parse(subscription: yaml)
        XCTAssertEqual(result.format, .clashYAML)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.name, "C")
    }

    func testEmptyThrows() {
        XCTAssertThrowsError(try subscriptions.parse(subscription: "   \n  "))
    }
}
