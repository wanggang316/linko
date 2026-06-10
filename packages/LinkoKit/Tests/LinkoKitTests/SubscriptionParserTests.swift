import XCTest
@testable import LinkoKit

final class SubscriptionParserTests: XCTestCase {
    private let parser = SubscriptionParser()

    private static let fullFixture = """
    port: 7890
    proxies:
      - name: "SS-HK"
        type: ss
        server: ss.example.com
        port: 8388
        cipher: aes-256-gcm
        password: ss-secret
      - name: "VMess-JP"
        type: vmess
        server: vm.example.com
        port: 443
        uuid: 11111111-2222-3333-4444-555555555555
        alterId: 0
        cipher: auto
        tls: true
        servername: cdn.example.com
        skip-cert-verify: true
      - name: "Trojan-US"
        type: trojan
        server: tj.example.com
        port: 443
        password: tj-secret
        sni: tj.example.com
      - name: "VLESS-SG"
        type: vless
        server: vl.example.com
        port: 443
        uuid: 66666666-7777-8888-9999-000000000000
        flow: xtls-rprx-vision
        tls: true
        servername: vl.example.com
      - name: "HY2-TW"
        type: hysteria2
        server: hy.example.com
        port: 443
        password: hy-secret
        sni: hy.example.com
        skip-cert-verify: false
      - name: "TUIC-KR"
        type: tuic
        server: tu.example.com
        port: 443
        uuid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
        password: tu-secret
        sni: tu.example.com
    """

    func testParsesAllSupportedTypes() throws {
        let result = try parser.parse(clashYAML: Self.fullFixture)
        XCTAssertEqual(result.nodes.count, 6)
        XCTAssertEqual(result.warnings, [])

        let ss = result.nodes[0]
        XCTAssertEqual(ss.name, "SS-HK")
        XCTAssertEqual(ss.protocolType, .shadowsocks)
        XCTAssertEqual(ss.server, "ss.example.com")
        XCTAssertEqual(ss.port, 8388)
        XCTAssertEqual(ss.method, "aes-256-gcm")
        XCTAssertEqual(ss.password, "ss-secret")
        XCTAssertFalse(ss.tlsEnabled)

        let vmess = result.nodes[1]
        XCTAssertEqual(vmess.protocolType, .vmess)
        XCTAssertEqual(vmess.uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(vmess.alterId, 0)
        XCTAssertTrue(vmess.tlsEnabled)
        XCTAssertEqual(vmess.sni, "cdn.example.com")
        XCTAssertTrue(vmess.allowInsecure)

        let trojan = result.nodes[2]
        XCTAssertEqual(trojan.protocolType, .trojan)
        XCTAssertEqual(trojan.password, "tj-secret")
        XCTAssertTrue(trojan.tlsEnabled)
        XCTAssertEqual(trojan.sni, "tj.example.com")
        XCTAssertFalse(trojan.allowInsecure)

        let vless = result.nodes[3]
        XCTAssertEqual(vless.protocolType, .vless)
        XCTAssertEqual(vless.flow, "xtls-rprx-vision")
        XCTAssertTrue(vless.tlsEnabled)
        XCTAssertEqual(vless.sni, "vl.example.com")

        let hysteria2 = result.nodes[4]
        XCTAssertEqual(hysteria2.protocolType, .hysteria2)
        XCTAssertEqual(hysteria2.password, "hy-secret")
        XCTAssertTrue(hysteria2.tlsEnabled)
        XCTAssertFalse(hysteria2.allowInsecure)

        let tuic = result.nodes[5]
        XCTAssertEqual(tuic.protocolType, .tuic)
        XCTAssertEqual(tuic.uuid, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(tuic.password, "tu-secret")
        XCTAssertTrue(tuic.tlsEnabled)
    }

    func testSkipsUnknownTypesWithWarning() throws {
        let yaml = """
        proxies:
          - name: "Snell-X"
            type: snell
            server: x.example.com
            port: 1
          - name: "SS-OK"
            type: ss
            server: ok.example.com
            port: 8388
            cipher: aes-128-gcm
            password: pw
        """
        let result = try parser.parse(clashYAML: yaml)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[0].name, "SS-OK")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("snell"))
    }

    func testSkipsEntriesMissingRequiredFields() throws {
        let yaml = """
        proxies:
          - name: "No-Server"
            type: ss
            port: 8388
            cipher: aes-128-gcm
            password: pw
          - name: "No-Cipher"
            type: ss
            server: a.example.com
            port: 8388
            password: pw
          - name: "Bad-Port"
            type: trojan
            server: b.example.com
            port: 0
            password: pw
          - name: "No-UUID"
            type: vmess
            server: c.example.com
            port: 443
          - type: ss
            server: unnamed.example.com
            port: 1
            cipher: aes-128-gcm
            password: pw
        """
        let result = try parser.parse(clashYAML: yaml)
        XCTAssertEqual(result.nodes.count, 0)
        XCTAssertEqual(result.warnings.count, 5)
    }

    func testToleratesStringPortAndStringBooleans() throws {
        let yaml = """
        proxies:
          - name: "Stringly"
            type: vmess
            server: s.example.com
            port: "443"
            uuid: u
            tls: "true"
        """
        let result = try parser.parse(clashYAML: yaml)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[0].port, 443)
        XCTAssertTrue(result.nodes[0].tlsEnabled)
    }

    func testNonMappingProxyEntryIsSkipped() throws {
        let yaml = """
        proxies:
          - "just a string"
          - name: "SS-OK"
            type: ss
            server: ok.example.com
            port: 8388
            cipher: aes-128-gcm
            password: pw
        """
        let result = try parser.parse(clashYAML: yaml)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testMissingProxiesSectionThrows() {
        XCTAssertThrowsError(try parser.parse(clashYAML: "port: 7890\nmode: rule")) { error in
            XCTAssertEqual(error as? SubscriptionParserError, .missingProxiesSection)
        }
    }

    func testInvalidYAMLThrows() {
        let malformed = "proxies:\n  - name: \"unterminated\n\t\tbroken: [yes"
        XCTAssertThrowsError(try parser.parse(clashYAML: malformed)) { error in
            guard case .invalidYAML = error as? SubscriptionParserError else {
                return XCTFail("expected invalidYAML, got \(error)")
            }
        }
    }

    func testNonMappingDocumentThrows() {
        XCTAssertThrowsError(try parser.parse(clashYAML: "- a\n- b")) { error in
            guard case .invalidYAML = error as? SubscriptionParserError else {
                return XCTFail("expected invalidYAML, got \(error)")
            }
        }
    }
}
