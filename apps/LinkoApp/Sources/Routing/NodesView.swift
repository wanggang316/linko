import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - NodesView
// =============================================================================

/// The 节点 (Nodes) browser: a native list of every node across all subscriptions
/// in the active profile, grouped by protocol, with a protocol badge + endpoint
/// per row and a `NodeDetailView` detail pane. This is where the protocol breadth
/// added this milestone becomes legible — WireGuard endpoints and SSH outbounds
/// appear alongside the existing protocols, each with their own glyph, and a
/// click reveals their key fields (interface address / pinned keys / auth method)
/// read-only.
///
/// Self-contained and window-ready: it reads `appState.allNodes` and selects the
/// active node via `appState.preferences.selectedNodeID` (read-only here; node
/// selection stays in the menu). A leading filter lets the user narrow to a
/// single protocol when a subscription mixes many.
///
/// Build-agent wiring note: to surface this as a Dashboard sidebar entry, add a
/// `case nodes` to `DashboardSection` (title "节点", included in
/// `selfChromedSections` so `isRoutingSection` is `true`), list it in the "订阅"
/// or a "节点" sidebar `Section`, and return `NodesView()` from
/// `DashboardView.detail`. The view declares its own `.navigationTitle("节点")`.
struct NodesView: View {
    @EnvironmentObject private var appState: AppState

    /// The protocol filter; `nil` shows every protocol.
    @State private var filter: NodeProtocol?
    /// The node selected in the list (drives the detail pane).
    @State private var selection: UUID?

    var body: some View {
        Group {
            if appState.allNodes.isEmpty {
                emptyState
            } else {
                splitContent
            }
        }
        .navigationTitle("节点")
        .toolbar { toolbarContent }
        .frame(minWidth: 640, minHeight: 440)
    }

    // MARK: - Derived state

    private var allNodes: [ProxyNode] { appState.allNodes }

    /// Protocols actually present, in `NodeProtocol.allCases` order, for the
    /// filter menu (so we never offer a filter that matches nothing).
    private var presentProtocols: [NodeProtocol] {
        let present = Set(allNodes.map(\.protocolType))
        return NodeProtocol.allCases.filter { present.contains($0) }
    }

    private var filteredNodes: [ProxyNode] {
        guard let filter else { return allNodes }
        return allNodes.filter { $0.protocolType == filter }
    }

    /// The filtered nodes grouped by protocol, each group in `NodeProtocol`
    /// declaration order, for the sectioned list.
    private var groupedNodes: [(proto: NodeProtocol, nodes: [ProxyNode])] {
        let grouped = Dictionary(grouping: filteredNodes, by: \.protocolType)
        return NodeProtocol.allCases.compactMap { proto in
            guard let nodes = grouped[proto], !nodes.isEmpty else { return nil }
            return (proto, nodes)
        }
    }

    private var selectedNode: ProxyNode? {
        guard let selection else { return nil }
        return allNodes.first { $0.id == selection }
    }

    // MARK: - Content

    private var splitContent: some View {
        HSplitView {
            list
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groupedNodes, id: \.proto) { group in
                Section {
                    ForEach(group.nodes) { node in
                        NodeListRow(
                            node: node,
                            isActive: node.id == appState.preferences.selectedNodeID
                        )
                        .tag(node.id)
                    }
                } header: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(ProtocolPresentation.title(group.proto))
                        CountBadge(count: group.nodes.count)
                    }
                }
            }
        }
        .listStyle(.inset)
        .animation(.easeInOut(duration: 0.15), value: filter)
    }

    @ViewBuilder
    private var detail: some View {
        if let node = selectedNode {
            NodeDetailView(node: node)
        } else {
            detailPlaceholder
        }
    }

    private var detailPlaceholder: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Theme.Color.tertiaryLabel)
            Text("选择一个节点查看详情")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.secondaryLabel)
            Text("WireGuard 与 SSH 节点会显示其接口地址、固定密钥与认证方式。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.tertiaryLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Theme.Color.accent.opacity(0.7))
            VStack(spacing: Theme.Spacing.xxs) {
                Text("暂无节点")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.label)
                Text("从订阅导入节点后，将在此浏览全部协议的节点，\n包括 WireGuard 与 SSH。")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    filter = nil
                } label: {
                    Label("全部协议", systemImage: filter == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(presentProtocols, id: \.self) { proto in
                    Button {
                        filter = proto
                    } label: {
                        Label(
                            ProtocolPresentation.title(proto),
                            systemImage: filter == proto ? "checkmark" : ProtocolPresentation.symbol(proto)
                        )
                    }
                }
            } label: {
                Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("按协议筛选节点")
        }
    }

    private var filterLabel: String {
        guard let filter else { return "全部协议" }
        return ProtocolPresentation.title(filter)
    }
}

// =============================================================================
// MARK: - NodeListRow
// =============================================================================

/// One node entry in the browser list: a leading protocol glyph, the name +
/// endpoint, a trailing protocol badge, and a small "使用中" marker when this is
/// the active profile's selected node.
private struct NodeListRow: View {
    let node: ProxyNode
    let isActive: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: ProtocolPresentation.symbol(node.protocolType))
                .font(.body)
                .foregroundStyle(isActive ? Theme.Color.accent : Theme.Color.secondaryLabel)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(Theme.Font.bodyEmphasized)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(node.server):\(node.port)")
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Spacing.xs)

            if isActive {
                Text("使用中")
                    .font(Theme.Font.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Color.accent)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Theme.Color.accent.opacity(0.14), in: Capsule())
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}
