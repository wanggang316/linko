import XCTest
@testable import LinkoKit

/// Covers the transport/security mapping the parser performs on top of the
/// basic credential fields: TLS (sni/alpn/utls/insecure), REALITY, the ws/grpc/
/// h2 transports, shadowsocks SIP003 plugins, and the hysteria2/tuic extras
/// folded into `pluginOpts`. Each test uses a realistic Clash snippet.
final class SubscriptionParserTransportTests: XCTestCase {
    private let parser = SubscriptionParser()

    /// Parses a single-proxy document and returns the lone node, failing the
    /// test if the entry was skipped.
    private func parseSingle(_ yaml: String, file: StaticString = #file, line: UInt = #line) throws -> ProxyNode {
        let result = try parser.parse(clashYAML: yaml)
        XCTAssertEqual(result.warnings, [], "unexpected warnings: \(result.warnings)", file: file, line: line)
        guard let node = result.nodes.first else {
            XCTFail("expected one node, got none (warnings: \(result.warnings))", file: file, line: line)
            throw NSError(domain: "test", code: 0)
        }
        return node
    }

    // MARK: - TLS basics

    func testTLSServerNameFromSNIAndServername() throws {
        // `sni` wins over `servername` when both are present.
        let bySNI = try parseSingle("""
        proxies:
          - name: "T1"
            type: vmess
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            sni: real.example.com
            servername: fallback.example.com
        """)
        XCTAssertEqual(bySNI.tls.serverName, "real.example.com")
        XCTAssertEqual(bySNI.sni, "real.example.com")
        XCTAssertTrue(bySNI.tls.enabled)

        // `servername` is used when `sni` is absent.
        let byServername = try parseSingle("""
        proxies:
          - name: "T2"
            type: vmess
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            servername: cdn.example.com
        """)
        XCTAssertEqual(byServername.tls.serverName, "cdn.example.com")
    }

    func testTLSAlpnListAndSingleScalar() throws {
        let listForm = try parseSingle("""
        proxies:
          - name: "ALPN-List"
            type: vless
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            alpn:
              - h2
              - http/1.1
        """)
        XCTAssertEqual(listForm.tls.alpn, ["h2", "http/1.1"])

        let scalarForm = try parseSingle("""
        proxies:
          - name: "ALPN-Scalar"
            type: vless
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            alpn: h3
        """)
        XCTAssertEqual(scalarForm.tls.alpn, ["h3"])
    }

    func testSkipCertVerifyMapsToInsecure() throws {
        let node = try parseSingle("""
        proxies:
          - name: "Insecure"
            type: trojan
            server: a.example.com
            port: 443
            password: pw
            skip-cert-verify: true
        """)
        XCTAssertTrue(node.tls.insecure)
        XCTAssertTrue(node.allowInsecure)
    }

    func testClientFingerprintMapsToUTLS() throws {
        let node = try parseSingle("""
        proxies:
          - name: "UTLS"
            type: vless
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            client-fingerprint: chrome
        """)
        XCTAssertEqual(node.tls.utlsFingerprint, .chrome)
    }

    func testUnknownClientFingerprintIsDropped() throws {
        // sing-box does not accept `360`/`qq` as utls presets in our enum;
        // the parser drops them instead of crashing.
        let node = try parseSingle("""
        proxies:
          - name: "UTLS-Unknown"
            type: vless
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            client-fingerprint: "360"
        """)
        XCTAssertNil(node.tls.utlsFingerprint)
    }

    // MARK: - REALITY

    func testRealityOptionsMapped() throws {
        // REALITY entries frequently omit `tls: true`; the parser must still
        // enable TLS because REALITY implies it.
        let node = try parseSingle("""
        proxies:
          - name: "Reality"
            type: vless
            server: a.example.com
            port: 443
            uuid: u
            flow: xtls-rprx-vision
            servername: www.microsoft.com
            client-fingerprint: chrome
            reality-opts:
              public-key: pk-abc123
              short-id: ff00
        """)
        XCTAssertTrue(node.tls.enabled)
        XCTAssertEqual(node.tls.serverName, "www.microsoft.com")
        XCTAssertEqual(node.flow, "xtls-rprx-vision")
        XCTAssertEqual(node.tls.utlsFingerprint, .chrome)
        let reality = try XCTUnwrap(node.tls.reality)
        XCTAssertTrue(reality.enabled)
        XCTAssertEqual(reality.publicKey, "pk-abc123")
        XCTAssertEqual(reality.shortID, "ff00")
    }

    func testRealityWithoutPublicKeyIsIgnored() throws {
        let node = try parseSingle("""
        proxies:
          - name: "Reality-Empty"
            type: vless
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            reality-opts:
              short-id: ff00
        """)
        XCTAssertNil(node.tls.reality)
    }

    // MARK: - WebSocket transport

    func testWebSocketTransportWithPathAndHostHeader() throws {
        let node = try parseSingle("""
        proxies:
          - name: "VMess-WS"
            type: vmess
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            network: ws
            ws-opts:
              path: /websocket
              headers:
                Host: edge.example.com
        """)
        XCTAssertEqual(node.transport.type, .ws)
        XCTAssertEqual(node.transport.path, "/websocket")
        // The Host header is promoted to transport.host and removed from headers.
        XCTAssertEqual(node.transport.host, ["edge.example.com"])
        XCTAssertNil(node.transport.headers["Host"])
    }

    func testWebSocketTransportKeepsNonHostHeaders() throws {
        let node = try parseSingle("""
        proxies:
          - name: "VLESS-WS"
            type: vless
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            network: ws
            ws-opts:
              path: /ray
              headers:
                Host: cdn.example.com
                User-Agent: linko/1.0
        """)
        XCTAssertEqual(node.transport.type, .ws)
        XCTAssertEqual(node.transport.host, ["cdn.example.com"])
        XCTAssertEqual(node.transport.headers["User-Agent"], "linko/1.0")
        XCTAssertNil(node.transport.headers["Host"])
    }

    func testWebSocketWithoutHostHeader() throws {
        let node = try parseSingle("""
        proxies:
          - name: "WS-NoHost"
            type: vmess
            server: a.example.com
            port: 443
            uuid: u
            network: ws
            ws-opts:
              path: /p
        """)
        XCTAssertEqual(node.transport.type, .ws)
        XCTAssertEqual(node.transport.path, "/p")
        XCTAssertEqual(node.transport.host, [])
    }

    // MARK: - gRPC transport

    func testGRPCTransport() throws {
        let node = try parseSingle("""
        proxies:
          - name: "VLESS-gRPC"
            type: vless
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            network: grpc
            grpc-opts:
              grpc-service-name: TunService
        """)
        XCTAssertEqual(node.transport.type, .grpc)
        XCTAssertEqual(node.transport.serviceName, "TunService")
    }

    // MARK: - HTTP/2 transport

    func testHTTP2Transport() throws {
        let node = try parseSingle("""
        proxies:
          - name: "VMess-H2"
            type: vmess
            server: a.example.com
            port: 443
            uuid: u
            tls: true
            network: h2
            h2-opts:
              host:
                - h2.example.com
              path: /h2path
        """)
        XCTAssertEqual(node.transport.type, .http)
        XCTAssertEqual(node.transport.host, ["h2.example.com"])
        XCTAssertEqual(node.transport.path, "/h2path")
    }

    func testHTTPTransportViaHTTPOpts() throws {
        // `network: http` carries options under `http-opts`.
        let node = try parseSingle("""
        proxies:
          - name: "VMess-HTTP"
            type: vmess
            server: a.example.com
            port: 443
            uuid: u
            network: http
            http-opts:
              path: /api
              headers:
                Host: api.example.com
        """)
        XCTAssertEqual(node.transport.type, .http)
        XCTAssertEqual(node.transport.path, "/api")
    }

    func testDefaultTransportIsTCP() throws {
        let node = try parseSingle("""
        proxies:
          - name: "Plain"
            type: vmess
            server: a.example.com
            port: 443
            uuid: u
        """)
        XCTAssertEqual(node.transport.type, .tcp)
        XCTAssertNil(node.transport.path)
        XCTAssertEqual(node.transport.host, [])
    }

    // MARK: - shadowsocks plugins

    func testShadowsocksObfsPlugin() throws {
        let node = try parseSingle("""
        proxies:
          - name: "SS-Obfs"
            type: ss
            server: a.example.com
            port: 8388
            cipher: aes-256-gcm
            password: pw
            plugin: obfs
            plugin-opts:
              mode: http
              host: bing.com
        """)
        XCTAssertEqual(node.plugin, "obfs-local")
        let opts = try XCTUnwrap(node.pluginOpts)
        XCTAssertTrue(opts.contains("obfs=http"), "opts: \(opts)")
        XCTAssertTrue(opts.contains("obfs-host=bing.com"), "opts: \(opts)")
    }

    func testShadowsocksV2RayPlugin() throws {
        let node = try parseSingle("""
        proxies:
          - name: "SS-V2Ray"
            type: ss
            server: a.example.com
            port: 8388
            cipher: aes-256-gcm
            password: pw
            plugin: v2ray-plugin
            plugin-opts:
              mode: websocket
              tls: true
              host: ws.example.com
              path: /vmpath
        """)
        XCTAssertEqual(node.plugin, "v2ray-plugin")
        let opts = try XCTUnwrap(node.pluginOpts)
        XCTAssertTrue(opts.contains("mode=websocket"), "opts: \(opts)")
        XCTAssertTrue(opts.contains("tls"), "opts: \(opts)")
        XCTAssertTrue(opts.contains("host=ws.example.com"), "opts: \(opts)")
        XCTAssertTrue(opts.contains("path=/vmpath"), "opts: \(opts)")
    }

    func testShadowsocksWithoutPlugin() throws {
        let node = try parseSingle("""
        proxies:
          - name: "SS-Plain"
            type: ss
            server: a.example.com
            port: 8388
            cipher: chacha20-ietf-poly1305
            password: pw
        """)
        XCTAssertNil(node.plugin)
        XCTAssertNil(node.pluginOpts)
    }

    // MARK: - hysteria2 extras

    func testHysteria2Extras() throws {
        let node = try parseSingle("""
        proxies:
          - name: "HY2"
            type: hysteria2
            server: a.example.com
            port: 443
            password: pw
            sni: hy.example.com
            up: "100 Mbps"
            down: "500 Mbps"
            obfs: salamander
            obfs-password: obfs-secret
            alpn:
              - h3
        """)
        XCTAssertTrue(node.tls.enabled)
        XCTAssertEqual(node.tls.serverName, "hy.example.com")
        XCTAssertEqual(node.tls.alpn, ["h3"])
        let opts = try XCTUnwrap(node.pluginOpts)
        XCTAssertTrue(opts.contains("up=100 Mbps"), "opts: \(opts)")
        XCTAssertTrue(opts.contains("down=500 Mbps"), "opts: \(opts)")
        XCTAssertTrue(opts.contains("obfs=salamander"), "opts: \(opts)")
        XCTAssertTrue(opts.contains("obfs-password=obfs-secret"), "opts: \(opts)")
    }

    func testHysteria2WithoutExtras() throws {
        let node = try parseSingle("""
        proxies:
          - name: "HY2-Plain"
            type: hysteria2
            server: a.example.com
            port: 443
            password: pw
            sni: hy.example.com
        """)
        XCTAssertNil(node.pluginOpts)
    }

    // MARK: - tuic extras

    func testTUICExtras() throws {
        let node = try parseSingle("""
        proxies:
          - name: "TUIC"
            type: tuic
            server: a.example.com
            port: 443
            uuid: uuid-1
            password: pw
            sni: tu.example.com
            congestion-controller: bbr
            udp-relay-mode: native
            alpn:
              - h3
        """)
        XCTAssertTrue(node.tls.enabled)
        XCTAssertEqual(node.tls.serverName, "tu.example.com")
        XCTAssertEqual(node.tls.alpn, ["h3"])
        XCTAssertEqual(node.uuid, "uuid-1")
        XCTAssertEqual(node.password, "pw")
        let opts = try XCTUnwrap(node.pluginOpts)
        XCTAssertTrue(opts.contains("congestion-control=bbr"), "opts: \(opts)")
        XCTAssertTrue(opts.contains("udp-relay-mode=native"), "opts: \(opts)")
    }

    // MARK: - combined / regression

    func testVMessWSTLSCombo() throws {
        // The canonical CDN-fronted vmess node: ws + tls + sni + utls.
        let node = try parseSingle("""
        proxies:
          - name: "VMess-WS-TLS"
            type: vmess
            server: cdn.example.com
            port: 443
            uuid: 11111111-2222-3333-4444-555555555555
            alterId: 0
            cipher: auto
            tls: true
            servername: real.example.com
            skip-cert-verify: false
            client-fingerprint: firefox
            network: ws
            ws-opts:
              path: /vm
              headers:
                Host: real.example.com
        """)
        XCTAssertEqual(node.protocolType, .vmess)
        XCTAssertTrue(node.tls.enabled)
        XCTAssertEqual(node.tls.serverName, "real.example.com")
        XCTAssertFalse(node.tls.insecure)
        XCTAssertEqual(node.tls.utlsFingerprint, .firefox)
        XCTAssertEqual(node.transport.type, .ws)
        XCTAssertEqual(node.transport.path, "/vm")
        XCTAssertEqual(node.transport.host, ["real.example.com"])
    }

    func testTrojanGRPCCombo() throws {
        let node = try parseSingle("""
        proxies:
          - name: "Trojan-gRPC"
            type: trojan
            server: a.example.com
            port: 443
            password: tj-secret
            sni: tj.example.com
            alpn:
              - h2
            network: grpc
            grpc-opts:
              grpc-service-name: GunService
        """)
        XCTAssertTrue(node.tls.enabled)
        XCTAssertEqual(node.tls.serverName, "tj.example.com")
        XCTAssertEqual(node.tls.alpn, ["h2"])
        XCTAssertEqual(node.transport.type, .grpc)
        XCTAssertEqual(node.transport.serviceName, "GunService")
    }

    func testMalformedTransportOptsDoesNotCrash() throws {
        // ws-opts given as a scalar (not a mapping) must degrade gracefully.
        let node = try parseSingle("""
        proxies:
          - name: "Bad-WS"
            type: vmess
            server: a.example.com
            port: 443
            uuid: u
            network: ws
            ws-opts: "not-a-mapping"
        """)
        XCTAssertEqual(node.transport.type, .ws)
        XCTAssertNil(node.transport.path)
        XCTAssertEqual(node.transport.host, [])
    }

    func testStringBooleanTLSStillEnables() throws {
        let node = try parseSingle("""
        proxies:
          - name: "StringTLS"
            type: vmess
            server: a.example.com
            port: 443
            uuid: u
            tls: "true"
        """)
        XCTAssertTrue(node.tls.enabled)
    }
}
