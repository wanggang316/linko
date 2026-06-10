import XCTest
@testable import LinkoKit

final class LinkoKitModelTests: XCTestCase {
    func testProxyNodeRoundTripsThroughJSON() throws {
        let node = ProxyNode(
            name: "HK-01",
            protocolType: .shadowsocks,
            server: "example.com",
            port: 8388,
            password: "secret",
            method: "aes-256-gcm"
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ProxyNode.self, from: data)
        XCTAssertEqual(decoded, node)
    }

    func testAppPreferencesDefaults() throws {
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs.mixedPort, 7890)
        XCTAssertEqual(prefs.clashAPIPort, 9090)
        XCTAssertNil(prefs.singBoxBinaryPathOverride)
    }

    func testNodeProtocolSingBoxTypeMapping() {
        XCTAssertEqual(NodeProtocol.shadowsocks.singBoxOutboundType, "shadowsocks")
        XCTAssertEqual(NodeProtocol.hysteria2.singBoxOutboundType, "hysteria2")
        XCTAssertEqual(NodeProtocol(rawValue: "ss"), .shadowsocks)
    }
}
