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
}
