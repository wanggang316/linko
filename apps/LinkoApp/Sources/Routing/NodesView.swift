import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - NodesView
// =============================================================================

/// The 节点 (Nodes) browser: a native list of every node in the active profile —
/// subscription nodes plus the user's hand-added manual nodes — grouped by
/// protocol, with a protocol badge + endpoint per row and a `NodeDetailView`
/// detail pane.
///
/// This is the management surface for nodes: a leading "+" mints a new manual
/// node via `NodeEditorView`; manual nodes can be edited, deleted, and set as
/// the active node; subscription nodes (overwritten on every refresh) stay
/// read-only but can be cloned into an editable manual node ("复制为可编辑节点").
/// Setting the active node here mirrors the menu — selection drives which node
/// routes traffic via `appState.selectNode`.
struct NodesView: View {
    @EnvironmentObject private var appState: AppState

    /// The protocol filter; `nil` shows every protocol.
    @State private var filter: NodeProtocol?
    /// The node selected in the list (drives the detail pane).
    @State private var selection: UUID?
    /// The presented editor sheet, if any.
    @State private var editor: Editor?

    /// Identifies which editor sheet is up: a fresh create, or an edit of an
    /// existing manual node.
    private enum Editor: Identifiable {
        case create
        case edit(ProxyNode)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let node): return node.id.uuidString
            }
        }
    }

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
        .sheet(item: $editor) { editor in
            NodeEditorView(node: editorNode(for: editor)) { saved in
                handleSave(editor, node: saved)
            }
        }
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
                            isActive: node.id == appState.preferences.selectedNodeID,
                            isManual: appState.isManualNode(node.id)
                        )
                        .tag(node.id)
                        .contextMenu { rowMenu(for: node) }
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
            VStack(spacing: 0) {
                detailActionBar(for: node)
                Divider()
                NodeDetailView(node: node)
            }
        } else {
            detailPlaceholder
        }
    }

    /// The action bar above a node's detail: set-active plus the edit/delete or
    /// clone affordances appropriate to whether the node is manual.
    private func detailActionBar(for node: ProxyNode) -> some View {
        let isActive = node.id == appState.preferences.selectedNodeID
        let isManual = appState.isManualNode(node.id)
        return HStack(spacing: Theme.Spacing.sm) {
            Button {
                appState.selectNode(id: node.id)
            } label: {
                Label(isActive ? "当前节点" : "设为当前节点", systemImage: isActive ? "checkmark.circle.fill" : "circle")
            }
            .disabled(isActive)

            Spacer(minLength: Theme.Spacing.xs)

            if isManual {
                Button {
                    editor = .edit(node)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Task { await appState.removeManualNode(id: node.id) }
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .tint(Theme.Color.error)
            } else if NodeEditorView.supports(node.protocolType) {
                Button {
                    cloneToManual(node)
                } label: {
                    Label("复制为可编辑节点", systemImage: "doc.on.doc")
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(Theme.Spacing.sm)
    }

    private var detailPlaceholder: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Theme.Color.tertiaryLabel)
            Text("选择一个节点查看详情")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.secondaryLabel)
            Text("点「+」可手动新增节点；订阅节点可复制为可编辑节点。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.tertiaryLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row context menu

    @ViewBuilder
    private func rowMenu(for node: ProxyNode) -> some View {
        let isActive = node.id == appState.preferences.selectedNodeID
        Button("设为当前节点") { appState.selectNode(id: node.id) }
            .disabled(isActive)
        Divider()
        if appState.isManualNode(node.id) {
            Button("编辑…") { editor = .edit(node) }
            Button("删除", role: .destructive) {
                Task { await appState.removeManualNode(id: node.id) }
            }
        } else if NodeEditorView.supports(node.protocolType) {
            Button("复制为可编辑节点") { cloneToManual(node) }
        }
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
                Text("从订阅导入，或点下方按钮手动新增一个节点。")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                editor = .create
            } label: {
                Label("新增节点", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
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
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    appState.openConfigFileInEditor()
                } label: {
                    Label("在编辑器中打开", systemImage: "square.and.pencil")
                }
                Button {
                    appState.revealConfigFileInFinder()
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
            } label: {
                Label("配置原文件", systemImage: "curlybraces")
            }
            .help("查看 / 编辑当前生成的 sing-box 配置原文件（config.json，每次启动或改节点会自动重新生成）")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                editor = .create
            } label: {
                Label("新增节点", systemImage: "plus")
            }
            .help("手动新增节点")
        }
    }

    private var filterLabel: String {
        guard let filter else { return "全部协议" }
        return ProtocolPresentation.title(filter)
    }

    // MARK: - Editor plumbing

    /// The node an editor sheet edits: `nil` for a fresh create, the target for
    /// an edit.
    private func editorNode(for editor: Editor) -> ProxyNode? {
        switch editor {
        case .create: return nil
        case .edit(let node):
            // Re-read from state so the form reflects the latest persisted value.
            return allNodes.first { $0.id == node.id } ?? node
        }
    }

    private func handleSave(_ editor: Editor, node: ProxyNode) {
        switch editor {
        case .create:
            appState.addManualNode(node)
            selection = node.id
        case .edit:
            Task { await appState.updateManualNode(node) }
        }
    }

    /// Clones a (read-only) subscription node into an editable manual copy, then
    /// opens it in the editor so the user can adjust it right away.
    private func cloneToManual(_ node: ProxyNode) {
        guard let newID = appState.duplicateNodeToManual(id: node.id),
              let copy = appState.allNodes.first(where: { $0.id == newID })
        else { return }
        selection = newID
        editor = .edit(copy)
    }
}

// =============================================================================
// MARK: - NodeListRow
// =============================================================================

/// One node entry in the browser list: a leading protocol glyph, the name +
/// endpoint, a trailing "手动" tag for manual nodes, and a small "使用中" marker
/// when this is the active profile's selected node.
private struct NodeListRow: View {
    let node: ProxyNode
    let isActive: Bool
    let isManual: Bool

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

            if isManual {
                Text("手动")
                    .font(Theme.Font.caption2.weight(.medium))
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Theme.Color.hover, in: Capsule())
            }

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
