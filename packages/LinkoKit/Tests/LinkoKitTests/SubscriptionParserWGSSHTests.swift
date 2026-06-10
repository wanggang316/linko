import XCTest
@testable import LinkoKit

/// Covers mapping Clash `type: wireguard` and `type: ssh` proxies into the new
/// `ProxyNode` WG/SSH fields, including skip-don't-crash for incomplete entries.
final class SubscriptionParserWGSSHTests: XCTestCase {
    private let parser = SubscriptionParser()

    func testParsesWireGuardProxy() throws {
        let yaml = """
        proxies:
          - name: WG-WARP
            type: wireguard
            server: 162.159.192.1
            port: 2408
            private-key: PRIVKEY
            public-key: PEERPUB
            pre-shared-key: PSK
            ip: 172.16.0.2/32
            ipv6: 2606:4700::2/128
            reserved: [12, 34, 56]
            mtu: 1280
        """
        let result = try parser.parse(clashYAML: yaml)
        XCTAssertEqual(result.nodes.count, 1)
        let node = try XCTUnwrap(result.nodes.first)
        XCTAssertEqual(node.protocolType, .wireguard)
        XCTAssertEqual(node.server, "162.159.192.1")
        XCTAssertEqual(node.port, 2408)
        let wg = try XCTUnwrap(node.wireGuard)
        XCTAssertEqual(wg.privateKey, "PRIVKEY")
        XCTAssertEqual(wg.peerPublicKey, "PEERPUB")
        XCTAssertEqual(wg.preSharedKey, "PSK")
        XCTAssertEqual(wg.localAddresses, ["172.16.0.2/32", "2606:4700::2/128"])
        XCTAssertEqual(wg.reserved, [12, 34, 56])
        XCTAssertEqual(wg.mtu, 1280)
    }

    func testNormalizesBareWireGuardAddressesToCIDR() throws {
        // Many real Clash.Meta / WARP subs store a bare IP with no prefix. The
        // builder emits these as the endpoint `address[]`, which sing-box parses
        // as a netip.Prefix and REJECTS without a `/` suffix. The parser must
        // append `/32` (IPv4) and `/128` (IPv6).
        let yaml = """
        proxies:
          - name: WG-WARP
            type: wireguard
            server: 162.159.192.1
            port: 2408
            private-key: PRIVKEY
            public-key: PEERPUB
            ip: 10.0.0.2
            ipv6: 2606:4700::2
        """
        let result = try parser.parse(clashYAML: yaml)
        let node = try XCTUnwrap(result.nodes.first)
        let wg = try XCTUnwrap(node.wireGuard)
        XCTAssertEqual(wg.localAddresses, ["10.0.0.2/32", "2606:4700::2/128"])
    }

    func testPreservesAlreadyPrefixedWireGuardAddresses() throws {
        let yaml = """
        proxies:
          - name: WG
            type: wireguard
            server: 1.2.3.4
            port: 51820
            private-key: PRIVKEY
            public-key: PEERPUB
            ip: 172.16.0.2/30
            ipv6: fd00::2/64
        """
        let result = try parser.parse(clashYAML: yaml)
        let wg = try XCTUnwrap(result.nodes.first?.wireGuard)
        XCTAssertEqual(wg.localAddresses, ["172.16.0.2/30", "fd00::2/64"])
    }

    func testDecodesBase64ReservedString() throws {
        // WARP encodes `reserved` as a base64 string of the 3 client-id bytes.
        // "AAAA" decodes to [0, 0, 0]; verify the bytes are preserved rather
        // than silently dropped.
        let yaml = """
        proxies:
          - name: WG-WARP
            type: wireguard
            server: 162.159.192.1
            port: 2408
            private-key: PRIVKEY
            public-key: PEERPUB
            ip: 10.0.0.2/32
            reserved: "AAAA"
        """
        let result = try parser.parse(clashYAML: yaml)
        let wg = try XCTUnwrap(result.nodes.first?.wireGuard)
        XCTAssertEqual(wg.reserved, [0, 0, 0])
    }

    func testDecodesNonZeroBase64ReservedString() throws {
        // base64 "AQID" decodes to bytes [1, 2, 3].
        let yaml = """
        proxies:
          - name: WG-WARP
            type: wireguard
            server: 162.159.192.1
            port: 2408
            private-key: PRIVKEY
            public-key: PEERPUB
            ip: 10.0.0.2/32
            reserved: "AQID"
        """
        let result = try parser.parse(clashYAML: yaml)
        let wg = try XCTUnwrap(result.nodes.first?.wireGuard)
        XCTAssertEqual(wg.reserved, [1, 2, 3])
    }

    func testParsesSSHProxy() throws {
        let yaml = """
        proxies:
          - name: SSH-Bastion
            type: ssh
            server: bastion.example.com
            port: 2222
            username: deploy
            password: s3cret
            host-key-algorithms: [ssh-ed25519]
        """
        let result = try parser.parse(clashYAML: yaml)
        let node = try XCTUnwrap(result.nodes.first)
        XCTAssertEqual(node.protocolType, .ssh)
        XCTAssertEqual(node.port, 2222)
        let ssh = try XCTUnwrap(node.ssh)
        XCTAssertEqual(ssh.user, "deploy")
        XCTAssertEqual(ssh.password, "s3cret")
        XCTAssertEqual(ssh.hostKeyAlgorithms, ["ssh-ed25519"])
    }

    func testSkipsWireGuardMissingPrivateKeyWithWarning() throws {
        let yaml = """
        proxies:
          - name: WG-Broken
            type: wireguard
            server: 1.2.3.4
            port: 51820
            public-key: PEERPUB
        """
        let result = try parser.parse(clashYAML: yaml)
        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("private-key"))
    }

    func testSkipsSSHMissingUserButKeepsOthers() throws {
        let yaml = """
        proxies:
          - name: SSH-Broken
            type: ssh
            server: 1.2.3.4
            port: 22
          - name: SS-OK
            type: ss
            server: s.example.com
            port: 8388
            cipher: aes-256-gcm
            password: pw
        """
        let result = try parser.parse(clashYAML: yaml)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.protocolType, .shadowsocks)
        XCTAssertEqual(result.warnings.count, 1)
    }
}
