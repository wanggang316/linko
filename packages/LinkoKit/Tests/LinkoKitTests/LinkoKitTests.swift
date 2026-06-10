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
        // New additive fields default safely for pre-existing persisted data.
        XCTAssertFalse(prefs.subscriptionAutoUpdateEnabled)
        XCTAssertEqual(prefs.subscriptionAutoUpdateMinutes, 60)
        XCTAssertFalse(prefs.launchAtLogin)
    }

    func testAppPreferencesClampsOutOfRangePortsOnDecode() throws {
        // Corrupted persisted ports (0, negative, > 65535) must fall back to
        // the defaults rather than producing an unusable config/URL.
        let json = #"{"mixedPort":0,"clashAPIPort":70000}"#
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.mixedPort, 7890)
        XCTAssertEqual(prefs.clashAPIPort, 9090)
    }

    func testAppPreferencesKeepsValidBoundaryPorts() throws {
        let json = #"{"mixedPort":1,"clashAPIPort":65535}"#
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.mixedPort, 1)
        XCTAssertEqual(prefs.clashAPIPort, 65535)
    }

    func testAppPreferencesClampsTooShortAutoUpdateInterval() throws {
        let json = #"{"subscriptionAutoUpdateMinutes":1}"#
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.subscriptionAutoUpdateMinutes, AppPreferences.minAutoUpdateMinutes)
    }

    func testAppPreferencesInitClampsPortsAndInterval() {
        let prefs = AppPreferences(mixedPort: -5, clashAPIPort: 99999, subscriptionAutoUpdateMinutes: 0)
        XCTAssertEqual(prefs.mixedPort, 7890)
        XCTAssertEqual(prefs.clashAPIPort, 9090)
        XCTAssertEqual(prefs.subscriptionAutoUpdateMinutes, AppPreferences.minAutoUpdateMinutes)
    }

    func testNodeProtocolSingBoxTypeMapping() {
        XCTAssertEqual(NodeProtocol.shadowsocks.singBoxOutboundType, "shadowsocks")
        XCTAssertEqual(NodeProtocol.hysteria2.singBoxOutboundType, "hysteria2")
        XCTAssertEqual(NodeProtocol(rawValue: "ss"), .shadowsocks)
    }
}
