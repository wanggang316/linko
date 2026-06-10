import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - RoutingTarget
// =============================================================================

/// A selectable outbound a rule (or `route.final`) can point at: a built-in
/// outbound, a user-defined policy group, or an individual proxy node. The
/// `tag` is the stable outbound tag the config builder assigns and is what the
/// rule actually stores in `RoutingRule.target`.
struct RoutingTarget: Identifiable, Hashable {
    enum Kind: Hashable {
        case builtin
        case group
        case node
    }

    var kind: Kind
    /// The outbound tag stored on the rule (matches a node/group/builtin tag).
    var tag: String
    /// Human-readable name shown in the picker (may equal `tag`).
    var displayName: String

    var id: String { "\(kind):\(tag)" }

    var symbolName: String {
        switch kind {
        case .builtin: return tag == "direct" ? "arrow.up.forward" : "bolt.horizontal.circle"
        case .group: return "rectangle.3.group"
        case .node: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

// =============================================================================
// MARK: - RoutingTargets
// =============================================================================

/// Resolves the set of outbound targets available to rules from the live
/// routing config and node list, and renders a target tag back into a
/// presentable `RoutingTarget`. A single source of truth shared by the rule
/// list rows and the editor's target picker.
struct RoutingTargets {
    /// Built-in outbounds always available regardless of configuration.
    let builtins: [RoutingTarget]
    /// User-defined policy groups, by tag.
    let groups: [RoutingTarget]
    /// Individual proxy nodes, by their deduplicated outbound tag.
    let nodes: [RoutingTarget]

    /// Builds the target catalogue from the persisted routing config and the
    /// builder-assigned node tags. Node tags are positionally aligned with
    /// `nodes`, exactly as the Clash API path expects.
    init(routing: RoutingConfig, nodes nodeList: [ProxyNode], nodeTags: [String]) {
        // "direct" is always present; "proxy" is the conventional default group
        // and is offered as a built-in even when no explicit group defines it,
        // since the builder synthesizes it.
        var builtinTargets: [RoutingTarget] = [
            RoutingTarget(kind: .builtin, tag: "direct", displayName: "直连 (direct)"),
        ]
        let hasProxyGroup = routing.groups.contains { $0.name == PolicyGroup.defaultGroupName }
        if !hasProxyGroup {
            builtinTargets.append(
                RoutingTarget(
                    kind: .builtin,
                    tag: PolicyGroup.defaultGroupName,
                    displayName: "代理 (proxy)"
                )
            )
        }
        self.builtins = builtinTargets

        self.groups = routing.groups.map { group in
            RoutingTarget(kind: .group, tag: group.name, displayName: group.name)
        }

        self.nodes = zip(nodeList, nodeTags).map { node, tag in
            RoutingTarget(kind: .node, tag: tag, displayName: node.name)
        }
    }

    /// All targets in picker order: built-ins, then groups, then nodes.
    var all: [RoutingTarget] { builtins + groups + nodes }

    /// The default target to assign to a freshly created rule: the "proxy"
    /// group if it exists, else the first available target.
    var defaultTag: String {
        if let proxy = all.first(where: { $0.tag == PolicyGroup.defaultGroupName }) {
            return proxy.tag
        }
        return all.first?.tag ?? PolicyGroup.defaultGroupName
    }

    /// Resolves a stored target tag into a presentable target. Unknown tags
    /// (e.g. imported policy names that don't yet match any group/node) are
    /// returned as a synthetic "unresolved" target so the row can flag them.
    func resolve(_ tag: String) -> RoutingTarget {
        if let known = all.first(where: { $0.tag == tag }) {
            return known
        }
        return RoutingTarget(kind: .builtin, tag: tag, displayName: tag)
    }

    /// `true` when `tag` matches a known node/group/built-in. Drives the
    /// "unresolved target" warning glyph on imported rules.
    func isResolved(_ tag: String) -> Bool {
        all.contains { $0.tag == tag }
    }
}
