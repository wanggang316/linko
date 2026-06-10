import XCTest
@testable import LinkoKit

/// Covers the new `.wireguard`/`.ssh` protocols at the model layer: protocol
/// metadata, tolerant `ProxyNode` decode of the WG/SSH config blocks, and the
/// config-generation shape (WireGuard as a top-level endpoint, SSH as an
/// outbound). The generated config is also validated against the real sing-box
/// binary when it is present.
final class WireGuardSSHNodeTests: XCTestCase {
    private let builder = SingBoxConfigBuilder()

    // MARK: - Protocol metadata

    func testProtocolMetadata() {
        XCTAssertEqual(NodeProtocol.wireguard.singBoxOutboundType, "wireguard")
        XCTAssertEqual(NodeProtocol.ssh.singBoxOutboundType, "ssh")
        XCTAssertTrue(NodeProtocol.wireguard.isEndpoint)
        XCTAssertFalse(NodeProtocol.ssh.isEndpoint)
        XCTAssertFalse(NodeProtocol.shadowsocks.isEndpoint)
        // New cases are part of the case-iterable set used by editors.
        XCTAssertTrue(NodeProtocol.allCases.contains(.wireguard))
        XCTAssertTrue(NodeProtocol.allCases.contains(.ssh))
    }

    // MARK: - Tolerant decode

    func testProxyNodeWithoutWGOrSSHDecodesNilBlocks() throws {
        // A pre-milestone node JSON (no wireGuard/ssh keys) still decodes.
        let json = """
        { "name": "HK", "protocolType": "ss", "server": "h", "port": 1,
          "password": "p", "method": "aes-256-gcm" }
        """
        let node = try JSONDecoder().decode(ProxyNode.self, from: Data(json.utf8))
        XCTAssertNil(node.wireGuard)
        XCTAssertNil(node.ssh)
    }

    func testWireGuardConfigRoundTripsAndToleratesMissingFields() throws {
        let json = """
        { "privateKey": "PRIV", "peerPublicKey": "PUB", "localAddresses": ["10.0.0.2/32"] }
        """
        let wg = try JSONDecoder().decode(WireGuardConfig.self, from: Data(json.utf8))
        XCTAssertEqual(wg.privateKey, "PRIV")
        XCTAssertEqual(wg.peerPublicKey, "PUB")
        XCTAssertEqual(wg.localAddresses, ["10.0.0.2/32"])
        XCTAssertNil(wg.preSharedKey)
        XCTAssertEqual(wg.reserved, [])
        XCTAssertNil(wg.mtu)

        let reencoded = try JSONEncoder().encode(wg)
        let decoded = try JSONDecoder().decode(WireGuardConfig.self, from: reencoded)
        XCTAssertEqual(decoded, wg)
    }

    func testWireGuardWithEmptyAddressThrowsInsteadOfDeadTunnel() {
        let node = ProxyNode(
            name: "WG", protocolType: .wireguard, server: "wg.example.com", port: 51820,
            wireGuard: WireGuardConfig(privateKey: "PRIV", peerPublicKey: "PEERPUB", localAddresses: [])
        )
        XCTAssertThrowsError(try builder.build(nodes: [node], preferences: AppPreferences())) { error in
            XCTAssertEqual(error as? SingBoxConfigError,
                           .missingField(node: "WG", field: "wireguard.address"))
        }
    }

    func testSSHConfigToleratesMissingFields() throws {
        let ssh = try JSONDecoder().decode(SSHConfig.self, from: Data("{ \"user\": \"root\" }".utf8))
        XCTAssertEqual(ssh.user, "root")
        XCTAssertNil(ssh.password)
        XCTAssertEqual(ssh.hostKey, [])
    }

    // MARK: - Config generation: WireGuard endpoint

    func testWireGuardBecomesEndpointNotOutbound() throws {
        let node = wireGuardNode()
        let data = try builder.build(nodes: [node], preferences: AppPreferences())
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // It must NOT be an outbound.
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertFalse(outbounds.contains { $0["type"] as? String == "wireguard" })

        // It must be a top-level endpoint.
        let endpoints = try XCTUnwrap(config["endpoints"] as? [[String: Any]])
        let wg = try XCTUnwrap(endpoints.first { $0["type"] as? String == "wireguard" })
        XCTAssertEqual(wg["tag"] as? String, "WG")
        XCTAssertEqual(wg["private_key"] as? String, "PRIV")
        XCTAssertEqual(wg["address"] as? [String], ["10.0.0.2/32"])
        XCTAssertEqual(wg["mtu"] as? Int, 1408)

        let peers = try XCTUnwrap(wg["peers"] as? [[String: Any]])
        let peer = try XCTUnwrap(peers.first)
        XCTAssertEqual(peer["address"] as? String, "wg.example.com")
        XCTAssertEqual(peer["port"] as? Int, 51820)
        XCTAssertEqual(peer["public_key"] as? String, "PEERPUB")
        XCTAssertEqual(peer["reserved"] as? [Int], [1, 2, 3])
        XCTAssertEqual(peer["persistent_keepalive_interval"] as? Int, 25)
    }

    func testWireGuardTagIsReferenceableAsOutboundTag() throws {
        // The selector (built when routing is empty) must include the WG tag, so
        // rules/groups can route through it like any outbound.
        let node = wireGuardNode()
        let data = try builder.build(nodes: [node], preferences: AppPreferences())
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        let selector = try XCTUnwrap(outbounds.first { $0["type"] as? String == "selector" })
        let members = try XCTUnwrap(selector["outbounds"] as? [String])
        XCTAssertTrue(members.contains("WG"))
    }

    // MARK: - Config generation: SSH outbound

    func testSSHBecomesOutbound() throws {
        let node = sshNode()
        let data = try builder.build(nodes: [node], preferences: AppPreferences())
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        let ssh = try XCTUnwrap(outbounds.first { $0["type"] as? String == "ssh" })
        XCTAssertEqual(ssh["tag"] as? String, "SSH")
        XCTAssertEqual(ssh["server"] as? String, "ssh.example.com")
        XCTAssertEqual(ssh["server_port"] as? Int, 22)
        XCTAssertEqual(ssh["user"] as? String, "root")
        XCTAssertEqual(ssh["password"] as? String, "hunter2")
        XCTAssertEqual(ssh["host_key_algorithms"] as? [String], ["ssh-ed25519"])
        XCTAssertNil(config["endpoints"], "SSH-only config must not emit an endpoints array")
    }

    // MARK: - Real sing-box validation (skipped when binary absent)

    func testMixedWGAndSSHConfigValidatesAgainstSingBox() throws {
        let binary = URL(fileURLWithPath:
            "/Users/wanggang/dev/00/linko/vendor/sing-box/sing-box")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "sing-box binary not available")

        // Use real 32-byte base64 keys so the WireGuard endpoint passes
        // sing-box's key decode (the shape tests use placeholder keys).
        let wg = ProxyNode(
            name: "WG", protocolType: .wireguard, server: "wg.example.com", port: 51820,
            wireGuard: WireGuardConfig(
                privateKey: "7MhapqcCXnAIeABZDRl0VJinSjxKEn/7fDvM+2QFBns=",
                peerPublicKey: "XeSZhRfGAk3dY/K1TDQT82ctniW3fHLF5XSHAKB6fLM=",
                preSharedKey: "t6nCLRflh4Etn1AjV/7Z9n4sxanKMclTo7IkovXPJj8=",
                localAddresses: ["10.0.0.2/32", "fd00::2/128"],
                reserved: [1, 2, 3],
                mtu: 1408,
                persistentKeepalive: 25
            )
        )
        let data = try builder.build(nodes: [wg, sshNode()], preferences: AppPreferences())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linko-wg-ssh-\(UUID().uuidString).json")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let validator = ConfigValidator()
        let result = validator.validate(configFileURL: url, binaryURL: binary)
        XCTAssertTrue(result.isValid, "errors: \(result.errors)")
    }

    // MARK: - Fixtures

    private func wireGuardNode() -> ProxyNode {
        ProxyNode(
            name: "WG", protocolType: .wireguard, server: "wg.example.com", port: 51820,
            wireGuard: WireGuardConfig(
                privateKey: "PRIV",
                peerPublicKey: "PEERPUB",
                localAddresses: ["10.0.0.2/32"],
                reserved: [1, 2, 3],
                mtu: 1408,
                persistentKeepalive: 25
            )
        )
    }

    private func sshNode() -> ProxyNode {
        ProxyNode(
            name: "SSH", protocolType: .ssh, server: "ssh.example.com", port: 22,
            ssh: SSHConfig(
                user: "root",
                password: "hunter2",
                hostKeyAlgorithms: ["ssh-ed25519"]
            )
        )
    }
}
