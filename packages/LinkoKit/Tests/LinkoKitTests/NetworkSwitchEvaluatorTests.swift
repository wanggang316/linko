import XCTest
@testable import LinkoKit

/// Tests for the network-based profile-switch matcher: IPv4 CIDR containment
/// and rule resolution (first enabled match wins).
final class NetworkSwitchEvaluatorTests: XCTestCase {
    private let home = UUID()
    private let office = UUID()
    private let mobile = UUID()

    // MARK: - CIDR containment

    func testCIDRContainment() {
        XCTAssertTrue(NetworkSwitchEvaluator.ipv4("192.168.1.42", inCIDR: "192.168.1.0/24"))
        XCTAssertFalse(NetworkSwitchEvaluator.ipv4("192.168.2.42", inCIDR: "192.168.1.0/24"))
        XCTAssertTrue(NetworkSwitchEvaluator.ipv4("10.3.4.5", inCIDR: "10.0.0.0/8"))
        XCTAssertFalse(NetworkSwitchEvaluator.ipv4("11.0.0.1", inCIDR: "10.0.0.0/8"))
        XCTAssertTrue(NetworkSwitchEvaluator.ipv4("172.16.5.9", inCIDR: "172.16.0.0/12"))
        XCTAssertFalse(NetworkSwitchEvaluator.ipv4("172.32.0.1", inCIDR: "172.16.0.0/12"))
    }

    func testCIDREdgeMasks() {
        // /32 = exact host, /0 = everything.
        XCTAssertTrue(NetworkSwitchEvaluator.ipv4("1.2.3.4", inCIDR: "1.2.3.4/32"))
        XCTAssertFalse(NetworkSwitchEvaluator.ipv4("1.2.3.5", inCIDR: "1.2.3.4/32"))
        XCTAssertTrue(NetworkSwitchEvaluator.ipv4("8.8.8.8", inCIDR: "0.0.0.0/0"))
        // A bare address is treated as /32.
        XCTAssertTrue(NetworkSwitchEvaluator.ipv4("1.2.3.4", inCIDR: "1.2.3.4"))
        XCTAssertFalse(NetworkSwitchEvaluator.ipv4("1.2.3.4", inCIDR: "1.2.3.5"))
    }

    func testCIDRRejectsGarbageAndIPv6() {
        XCTAssertFalse(NetworkSwitchEvaluator.ipv4("not-an-ip", inCIDR: "192.168.1.0/24"))
        XCTAssertFalse(NetworkSwitchEvaluator.ipv4("192.168.1.1", inCIDR: "garbage"))
        XCTAssertFalse(NetworkSwitchEvaluator.ipv4("192.168.1.1", inCIDR: "192.168.1.0/40"))
        XCTAssertFalse(NetworkSwitchEvaluator.ipv4("fd00::1", inCIDR: "fd00::/8"))
    }

    // MARK: - Rule resolution

    func testSubnetRuleMatches() {
        let rules = [
            NetworkSwitchRule(kind: .subnet, value: "192.168.1.0/24", profileID: home),
        ]
        let snap = NetworkSnapshot(interface: .wifi, ipv4Addresses: ["192.168.1.50"])
        XCTAssertEqual(NetworkSwitchEvaluator.matchedProfileID(rules: rules, snapshot: snap), home)
    }

    func testInterfaceRuleMatches() {
        let rules = [
            NetworkSwitchRule(kind: .interface, value: NetworkInterfaceKind.wired.rawValue, profileID: office),
        ]
        let snap = NetworkSnapshot(interface: .wired, ipv4Addresses: ["10.0.0.9"])
        XCTAssertEqual(NetworkSwitchEvaluator.matchedProfileID(rules: rules, snapshot: snap), office)
    }

    func testFirstEnabledMatchWins() {
        let rules = [
            NetworkSwitchRule(kind: .subnet, value: "10.0.0.0/8", profileID: office, isEnabled: false),
            NetworkSwitchRule(kind: .subnet, value: "192.168.0.0/16", profileID: home),
            NetworkSwitchRule(kind: .interface, value: "wifi", profileID: mobile),
        ]
        let snap = NetworkSnapshot(interface: .wifi, ipv4Addresses: ["192.168.5.5"])
        // The disabled office rule is skipped; the home subnet rule wins over
        // the later wifi-interface rule.
        XCTAssertEqual(NetworkSwitchEvaluator.matchedProfileID(rules: rules, snapshot: snap), home)
    }

    func testNoMatchReturnsNil() {
        let rules = [
            NetworkSwitchRule(kind: .subnet, value: "10.0.0.0/8", profileID: office),
        ]
        let snap = NetworkSnapshot(interface: .wifi, ipv4Addresses: ["192.168.1.1"])
        XCTAssertNil(NetworkSwitchEvaluator.matchedProfileID(rules: rules, snapshot: snap))
    }

    func testEmptyOrInvalidValuesNeverMatch() {
        let rules = [
            NetworkSwitchRule(kind: .subnet, value: "", profileID: home),
            NetworkSwitchRule(kind: .interface, value: "", profileID: office),
        ]
        let snap = NetworkSnapshot(interface: .wifi, ipv4Addresses: ["192.168.1.1"])
        XCTAssertNil(NetworkSwitchEvaluator.matchedProfileID(rules: rules, snapshot: snap))
    }
}
