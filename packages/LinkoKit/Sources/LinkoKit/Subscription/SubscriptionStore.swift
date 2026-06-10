import Foundation

/// Pure, offline-testable helpers for managing a `[Subscription]` collection:
/// merge-by-url upsert (so re-importing the same URL replaces in place instead
/// of duplicating) and queries the app uses to decide whether a mutation
/// affects the running config. No I/O, no actor isolation — all logic that the
/// app's `AppState` would otherwise inline and could not test offline.
public enum SubscriptionStore {
    /// Inserts `incoming` into `subscriptions`, or, when an existing entry has
    /// the same `url`, replaces that entry in place while preserving the
    /// existing `id` and user-assigned `name` (a refresh must not reset a
    /// renamed subscription or invalidate references to its id). Returns the
    /// updated array; the input is not mutated.
    public static func upsert(
        _ incoming: Subscription,
        into subscriptions: [Subscription]
    ) -> [Subscription] {
        var result = subscriptions
        if let index = result.firstIndex(where: { $0.url == incoming.url }) {
            var merged = incoming
            merged.id = result[index].id
            merged.name = result[index].name
            result[index] = merged
        } else {
            result.append(incoming)
        }
        return result
    }

    /// `true` when any node produced by the subscription with `id` is the
    /// currently selected node — i.e. mutating/removing it would change what
    /// the running config routes through, requiring a (validated) restart.
    public static func subscriptionBacksSelection(
        id: UUID,
        selectedNodeID: UUID?,
        subscriptions: [Subscription]
    ) -> Bool {
        guard let selectedNodeID,
              let subscription = subscriptions.first(where: { $0.id == id })
        else { return false }
        return subscription.nodes.contains { $0.id == selectedNodeID }
    }

    /// The id of the first node across all subscriptions, used to repair a
    /// dangling selection after a removal/refresh drops the selected node.
    public static func firstNodeID(in subscriptions: [Subscription]) -> UUID? {
        subscriptions.first(where: { !$0.nodes.isEmpty })?.nodes.first?.id
    }

    /// `true` when `selectedNodeID` no longer resolves to any node across
    /// `subscriptions` (the selection became dangling after a mutation).
    public static func selectionIsDangling(
        selectedNodeID: UUID?,
        subscriptions: [Subscription]
    ) -> Bool {
        guard let selectedNodeID else { return false }
        return !subscriptions.contains { sub in
            sub.nodes.contains { $0.id == selectedNodeID }
        }
    }

    /// A stable identity for a node across refreshes. The parser assigns a
    /// fresh `UUID` on every parse, so the persisted `selectedNodeID` would go
    /// stale whenever its subscription is refreshed. This connection-derived
    /// key (protocol + server + port + display name) lets the selection be
    /// re-mapped onto the re-parsed node that represents the "same" server.
    public static func identityKey(for node: ProxyNode) -> String {
        "\(node.protocolType.rawValue)|\(node.server)|\(node.port)|\(node.name)"
    }

    /// Re-maps `selectedNodeID` after a refresh. Given the node that was
    /// selected *before* the refresh (`previousSelected`) and the new set of
    /// `subscriptions`, returns the id of the node that now represents the
    /// same server (matched by `identityKey`), or `nil` when no equivalent
    /// node survived the refresh. Returns `previousSelected?.id` unchanged
    /// when that exact id still exists (no re-map needed).
    public static func remapSelection(
        previousSelected: ProxyNode?,
        subscriptions: [Subscription]
    ) -> UUID? {
        guard let previousSelected else { return nil }
        let allNodes = subscriptions.flatMap(\.nodes)
        if allNodes.contains(where: { $0.id == previousSelected.id }) {
            return previousSelected.id
        }
        let key = identityKey(for: previousSelected)
        return allNodes.first(where: { identityKey(for: $0) == key })?.id
    }
}
