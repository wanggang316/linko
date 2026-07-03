import LinkoKit
import XCTest

/// Unit tests for `RoutingTargets`' node-entry construction: entries must be
/// keyed and displayed by the builder-assigned outbound tag whenever it
/// diverged from the raw node name (deduplicated collisions), so a node
/// literally named "reject" can never masquerade as the built-in reject item.
final class RoutingTargetsTests: XCTestCase {

    private func node(named name: String) -> ProxyNode {
        ProxyNode(name: name, protocolType: .shadowsocks, server: "\(name).example.com",
                  port: 8388, password: "pw", method: "aes-256-gcm")
    }

    func testNodeWithDedupedTagDisplaysTheTagNotTheRawName() {
        // The builder deduplicates a node named "reject" to the tag
        // "reject-2"; the menu must show that tag, or the node would be
        // indistinguishable from the built-in reject entry.
        let targets = RoutingTargets(
            routing: .empty,
            nodes: [node(named: "reject"), node(named: "HK")],
            nodeTags: ["reject-2", "HK"]
        )

        XCTAssertEqual(targets.nodes.map(\.tag), ["reject-2", "HK"])
        XCTAssertEqual(targets.nodes.map(\.displayName), ["reject-2", "HK"])
    }

    func testNodeWithMatchingTagKeepsItsName() {
        let targets = RoutingTargets(routing: .empty, nodes: [node(named: "HK")], nodeTags: ["HK"])

        XCTAssertEqual(targets.nodes.map(\.displayName), ["HK"])
    }

    func testEmptyCatalogueSynthesizesProxyAndOffersNoEmptySections() {
        // VAL-QUICKADD-015: with zero nodes and zero groups the catalogue
        // still offers the built-ins with a synthesized "proxy" — the default
        // target — and it resolves cleanly, so a rule saved against it shows
        // no warning. Empty `groups`/`nodes` are what keep `TargetMenuItems`
        // from rendering empty 策略组/节点 sections.
        let targets = RoutingTargets(routing: .empty, nodes: [], nodeTags: [])

        XCTAssertEqual(targets.builtins.map(\.tag), ["direct", "proxy", "reject"])
        XCTAssertTrue(targets.groups.isEmpty)
        XCTAssertTrue(targets.nodes.isEmpty)
        XCTAssertEqual(targets.defaultTag, "proxy")
        XCTAssertTrue(targets.isResolved("proxy"))
        XCTAssertEqual(targets.resolve("proxy").displayName, "代理 (proxy)")
    }
}
