import XCTest
@testable import LinkoKit

/// Offline tests for the pure subscription-management logic that backs
/// `AppState`'s add/refresh/remove flows: merge-by-url dedupe, selection
/// re-mapping across a refresh (where the parser mints fresh UUIDs), and the
/// "does this mutation affect the running config" queries.
final class SubscriptionStoreTests: XCTestCase {

    private func node(
        name: String,
        server: String,
        port: Int = 443,
        protocolType: NodeProtocol = .trojan,
        id: UUID = UUID()
    ) -> ProxyNode {
        ProxyNode(id: id, name: name, protocolType: protocolType, server: server, port: port, password: "p")
    }

    private func sub(
        name: String,
        url: String,
        nodes: [ProxyNode],
        id: UUID = UUID()
    ) -> Subscription {
        Subscription(id: id, name: name, url: URL(string: url)!, nodes: nodes)
    }

    // MARK: - upsert (merge-by-url dedupe)

    func testUpsertAppendsWhenURLIsNew() {
        let existing = [sub(name: "A", url: "https://a.example/sub", nodes: [node(name: "n1", server: "s1")])]
        let incoming = sub(name: "B", url: "https://b.example/sub", nodes: [node(name: "n2", server: "s2")])
        let result = SubscriptionStore.upsert(incoming, into: existing)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last?.url, incoming.url)
    }

    func testUpsertReplacesInPlaceForSameURL() {
        let originalID = UUID()
        let existing = [
            sub(name: "Renamed By User", url: "https://a.example/sub",
                nodes: [node(name: "old", server: "s1")], id: originalID),
        ]
        // A refresh: same URL, fresh id + auto-derived name + new nodes.
        let incoming = sub(name: "a.example", url: "https://a.example/sub",
                           nodes: [node(name: "fresh", server: "s2")])
        let result = SubscriptionStore.upsert(incoming, into: existing)

        XCTAssertEqual(result.count, 1, "Same URL must replace in place, not duplicate.")
        XCTAssertEqual(result[0].id, originalID, "Existing id is preserved across a refresh.")
        XCTAssertEqual(result[0].name, "Renamed By User", "User-assigned name is preserved.")
        XCTAssertEqual(result[0].nodes.map(\.name), ["fresh"], "Nodes are replaced with the fresh parse.")
    }

    func testUpsertIsDistinctByURL() {
        var subs: [Subscription] = []
        subs = SubscriptionStore.upsert(sub(name: "A", url: "https://a/sub", nodes: []), into: subs)
        subs = SubscriptionStore.upsert(sub(name: "B", url: "https://b/sub", nodes: []), into: subs)
        subs = SubscriptionStore.upsert(sub(name: "A2", url: "https://a/sub", nodes: []), into: subs)
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(Set(subs.map(\.url.absoluteString)), ["https://a/sub", "https://b/sub"])
    }

    // MARK: - subscriptionBacksSelection

    func testSubscriptionBacksSelectionTrueWhenSelectedNodeBelongs() {
        let selected = node(name: "sel", server: "s")
        let subID = UUID()
        let subs = [sub(name: "A", url: "https://a/sub", nodes: [selected], id: subID)]
        XCTAssertTrue(SubscriptionStore.subscriptionBacksSelection(
            id: subID, selectedNodeID: selected.id, subscriptions: subs))
    }

    func testSubscriptionBacksSelectionFalseForUnrelatedSubscription() {
        let selected = node(name: "sel", server: "s")
        let backingID = UUID()
        let otherID = UUID()
        let subs = [
            sub(name: "A", url: "https://a/sub", nodes: [selected], id: backingID),
            sub(name: "B", url: "https://b/sub", nodes: [node(name: "x", server: "y")], id: otherID),
        ]
        XCTAssertFalse(SubscriptionStore.subscriptionBacksSelection(
            id: otherID, selectedNodeID: selected.id, subscriptions: subs))
    }

    func testSubscriptionBacksSelectionFalseWhenNoSelection() {
        let subID = UUID()
        let subs = [sub(name: "A", url: "https://a/sub", nodes: [node(name: "n", server: "s")], id: subID)]
        XCTAssertFalse(SubscriptionStore.subscriptionBacksSelection(
            id: subID, selectedNodeID: nil, subscriptions: subs))
    }

    // MARK: - firstNodeID / selectionIsDangling

    func testFirstNodeIDSkipsEmptySubscriptions() {
        let wanted = node(name: "first", server: "s")
        let subs = [
            sub(name: "empty", url: "https://e/sub", nodes: []),
            sub(name: "A", url: "https://a/sub", nodes: [wanted, node(name: "second", server: "s2")]),
        ]
        XCTAssertEqual(SubscriptionStore.firstNodeID(in: subs), wanted.id)
    }

    func testFirstNodeIDNilWhenAllEmpty() {
        let subs = [sub(name: "empty", url: "https://e/sub", nodes: [])]
        XCTAssertNil(SubscriptionStore.firstNodeID(in: subs))
    }

    func testSelectionIsDanglingWhenIDAbsent() {
        let subs = [sub(name: "A", url: "https://a/sub", nodes: [node(name: "n", server: "s")])]
        XCTAssertTrue(SubscriptionStore.selectionIsDangling(selectedNodeID: UUID(), subscriptions: subs))
    }

    func testSelectionNotDanglingWhenIDPresent() {
        let present = node(name: "n", server: "s")
        let subs = [sub(name: "A", url: "https://a/sub", nodes: [present])]
        XCTAssertFalse(SubscriptionStore.selectionIsDangling(selectedNodeID: present.id, subscriptions: subs))
    }

    func testSelectionNotDanglingWhenNil() {
        XCTAssertFalse(SubscriptionStore.selectionIsDangling(selectedNodeID: nil, subscriptions: []))
    }

    // MARK: - identityKey / remapSelection (refresh re-mapping)

    func testIdentityKeyStableAcrossFreshUUIDForSameServer() {
        let a = node(name: "Tokyo", server: "tk.example", port: 443, protocolType: .vmess, id: UUID())
        let b = node(name: "Tokyo", server: "tk.example", port: 443, protocolType: .vmess, id: UUID())
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(SubscriptionStore.identityKey(for: a), SubscriptionStore.identityKey(for: b))
    }

    func testIdentityKeyDiffersWhenServerOrPortDiffers() {
        let a = node(name: "Tokyo", server: "tk.example", port: 443)
        let b = node(name: "Tokyo", server: "tk.example", port: 8443)
        let c = node(name: "Tokyo", server: "osaka.example", port: 443)
        XCTAssertNotEqual(SubscriptionStore.identityKey(for: a), SubscriptionStore.identityKey(for: b))
        XCTAssertNotEqual(SubscriptionStore.identityKey(for: a), SubscriptionStore.identityKey(for: c))
    }

    func testRemapSelectionFindsSameServerAfterRefresh() {
        // Selected before refresh.
        let before = node(name: "Tokyo", server: "tk.example", port: 443, protocolType: .vmess, id: UUID())
        // After refresh: same server, fresh UUID.
        let after = node(name: "Tokyo", server: "tk.example", port: 443, protocolType: .vmess, id: UUID())
        let subs = [sub(name: "A", url: "https://a/sub", nodes: [after, node(name: "Other", server: "x")])]

        let remapped = SubscriptionStore.remapSelection(previousSelected: before, subscriptions: subs)
        XCTAssertEqual(remapped, after.id, "Selection should re-map onto the re-parsed node for the same server.")
    }

    func testRemapSelectionKeepsExactIDWhenStillPresent() {
        let stable = node(name: "Tokyo", server: "tk.example")
        let subs = [sub(name: "A", url: "https://a/sub", nodes: [stable])]
        XCTAssertEqual(
            SubscriptionStore.remapSelection(previousSelected: stable, subscriptions: subs),
            stable.id
        )
    }

    func testRemapSelectionNilWhenServerGone() {
        let before = node(name: "Tokyo", server: "tk.example", id: UUID())
        let subs = [sub(name: "A", url: "https://a/sub", nodes: [node(name: "Osaka", server: "osaka.example")])]
        XCTAssertNil(SubscriptionStore.remapSelection(previousSelected: before, subscriptions: subs))
    }

    func testRemapSelectionNilWhenNoPreviousSelection() {
        XCTAssertNil(SubscriptionStore.remapSelection(previousSelected: nil, subscriptions: []))
    }
}
