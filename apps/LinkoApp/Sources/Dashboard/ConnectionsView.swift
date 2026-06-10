import LinkoKit
import SwiftUI

/// The 连接 (Connections) surface: a native `Table` of every live connection
/// with columns for process, destination, network, rule, proxy chain, byte
/// counts, and age. Columns are click-to-sort (default: newest first) via a
/// `sortOrder` binding.
///
/// Beyond the table it adds the power features that beat Surge's connection
/// view: a search field (matching host/process/rule), a network/type filter,
/// working 关闭 actions (close one via swipe or context menu, close all via the
/// toolbar), and a native inspector showing the selected connection's chains,
/// rule, timing, and byte breakdown. Empty (no connections) and stopped (core
/// down) states stay crafted via `DashboardEmptyState`.
struct ConnectionsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var viewModel: DashboardViewModel

    /// Drives the table's selection; targets the context-menu / swipe actions
    /// and the inspector's detail content.
    @State private var selection: ClashConnection.ID?
    /// Column sort order. Defaults to newest-first (descending start date), the
    /// natural reverse-chronological view; clicking any sortable header rebinds
    /// it and shows the native sort-direction triangle.
    @State private var sortOrder: [KeyPathComparator<ClashConnection>] = [
        KeyPathComparator(\.startDate, order: .reverse)
    ]
    /// Free-text filter applied to process / destination / rule / chain.
    @State private var searchText = ""
    /// Network/type filter (全部 / TCP / UDP).
    @State private var networkFilter: NetworkFilter = .all
    /// Whether the per-connection detail inspector is shown.
    @State private var showsInspector = false
    /// Re-evaluated once per second so the "时长" (age) column ticks live even
    /// when the snapshot itself hasn't changed.
    @State private var now = Date()

    private let ageTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The connections that survive the active search + network filters, then
    /// sorted by the current column order. The view model no longer pre-sorts.
    private var visibleConnections: [ClashConnection] {
        viewModel.connections
            .filter { networkFilter.matches($0) }
            .filter { matchesSearch($0) }
            .sorted(using: sortOrder)
    }

    /// The currently selected connection, resolved against the live snapshot so
    /// the inspector tracks byte/age updates rather than a stale copy.
    private var selectedConnection: ClashConnection? {
        guard let selection else { return nil }
        return viewModel.connections.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if !appState.isCoreRunning {
                DashboardEmptyState(
                    symbolName: "bolt.horizontal.circle",
                    title: "核心未运行",
                    message: "开启系统代理后，这里会实时显示所有活跃连接。"
                )
            } else if viewModel.connections.isEmpty {
                DashboardEmptyState(
                    symbolName: "point.3.connected.trianglepath.dotted",
                    title: "暂无活跃连接",
                    message: "当有流量经过代理时，连接会出现在这里。"
                )
            } else {
                connectionsTable
                    .overlay {
                        // The filters can empty an otherwise non-empty table;
                        // keep that case crafted too rather than a blank Table.
                        if visibleConnections.isEmpty {
                            DashboardEmptyState(
                                symbolName: "line.3.horizontal.decrease.circle",
                                title: "没有匹配的连接",
                                message: "调整搜索关键词或网络筛选，以查看更多连接。"
                            )
                        }
                    }
            }
        }
        .searchable(
            text: $searchText,
            placement: .automatic,
            prompt: "搜索进程、目标或规则"
        )
        .toolbar { toolbar }
        .inspector(isPresented: $showsInspector) {
            ConnectionInspector(connection: selectedConnection, now: now)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 380)
        }
        .onReceive(ageTimer) { now = $0 }
    }

    // MARK: - Table

    private var connectionsTable: some View {
        Table(visibleConnections, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("进程", value: \.processSortKey) { connection in
                Text(connection.friendlyProcessName)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .help(connection.metadata.processPath)
            }
            .width(min: 110, ideal: 140)

            TableColumn("目标", value: \.metadata.destinationDisplay) { connection in
                Text(connection.metadata.destinationDisplay)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(connection.metadata.destinationDisplay)
            }
            .width(min: 160, ideal: 220)

            TableColumn("网络", value: \.metadata.network) { connection in
                Text(connection.metadata.network.uppercased())
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
            .width(min: 48, ideal: 56, max: 70)

            TableColumn("规则", value: \.rule) { connection in
                Text(connection.rule.isEmpty ? "—" : connection.rule)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 80)

            TableColumn("链路", value: \.chainSortKey) { connection in
                Text(connection.exitNodeDisplay)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(connection.chains.joined(separator: " → "))
            }
            .width(min: 80, ideal: 120)

            TableColumn("上传", value: \.upload) { connection in
                Text(ByteFormatter.string(fromBytes: connection.upload))
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.upload)
            }
            .width(min: 64, ideal: 78, max: 100)

            TableColumn("下载", value: \.download) { connection in
                Text(ByteFormatter.string(fromBytes: connection.download))
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.download)
            }
            .width(min: 64, ideal: 78, max: 100)

            // Sorting by start date (ascending) puts the oldest connection
            // first, i.e. the longest-running — the natural reading of "时长".
            TableColumn("时长", value: \.startDate) { connection in
                Text(DurationFormatter.ageString(sinceRFC3339: connection.start, now: now))
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
            }
            .width(min: 48, ideal: 60, max: 80)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: ClashConnection.ID.self) { ids in
            connectionContextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click opens the detail inspector on that connection.
            if let id = ids.first {
                selection = id
                showsInspector = true
            }
        }
    }

    /// Context-menu actions for the right-clicked row(s): show details and
    /// close. Operates on the clicked id even when it isn't the current
    /// selection, matching native list-row behavior.
    @ViewBuilder
    private func connectionContextMenu(for ids: Set<ClashConnection.ID>) -> some View {
        if let id = ids.first {
            Button {
                selection = id
                showsInspector = true
            } label: {
                Label("查看详情", systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive) {
                viewModel.closeConnection(id: id)
            } label: {
                Label("关闭此连接", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("网络", selection: $networkFilter) {
                ForEach(NetworkFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .help("按网络类型筛选")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                showsInspector.toggle()
            } label: {
                Label("详情", systemImage: "sidebar.right")
            }
            .help("显示连接详情")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                viewModel.closeAllConnections()
            } label: {
                Label("关闭全部连接", systemImage: "xmark.circle.fill")
            }
            .help("关闭全部连接")
            .disabled(viewModel.connections.isEmpty)
        }
    }

    // MARK: - Filtering

    /// Case-insensitive substring match across the fields a user would search
    /// by: friendly process name, destination (host:port), matched rule, and
    /// the proxy chain tags. An empty query matches everything.
    private func matchesSearch(_ connection: ClashConnection) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        let haystacks = [
            connection.friendlyProcessName,
            connection.metadata.destinationDisplay,
            connection.metadata.host,
            connection.rule,
            connection.chains.joined(separator: " ")
        ]
        return haystacks.contains { $0.lowercased().contains(needle) }
    }
}

// =============================================================================
// MARK: - NetworkFilter
// =============================================================================

/// The network/type filter shown in the toolbar. `tcp`/`udp` match the
/// connection's `metadata.network` (sing-box emits lowercase); `all` passes
/// everything through.
private enum NetworkFilter: String, CaseIterable, Identifiable {
    case all
    case tcp
    case udp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部网络"
        case .tcp: return "TCP"
        case .udp: return "UDP"
        }
    }

    /// Whether a connection passes this filter.
    func matches(_ connection: ClashConnection) -> Bool {
        switch self {
        case .all: return true
        case .tcp: return connection.metadata.network.lowercased() == "tcp"
        case .udp: return connection.metadata.network.lowercased() == "udp"
        }
    }
}

// =============================================================================
// MARK: - ConnectionInspector
// =============================================================================

/// The per-connection detail shown in the native inspector: the full proxy
/// chain, matched rule, timing, and a byte breakdown. Renders a quiet
/// placeholder when nothing is selected so the inspector is never blank.
private struct ConnectionInspector: View {
    let connection: ClashConnection?
    let now: Date

    var body: some View {
        Group {
            if let connection {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        header(for: connection)
                        chainCard(for: connection)
                        routingCard(for: connection)
                        trafficCard(for: connection)
                    }
                    .padding(Theme.Spacing.md)
                }
                .scrollContentBackground(.hidden)
            } else {
                DashboardEmptyState(
                    symbolName: "info.circle",
                    title: "未选择连接",
                    message: "在左侧列表中选择一条连接以查看详情。"
                )
            }
        }
    }

    // MARK: Header

    private func header(for connection: ClashConnection) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(connection.friendlyProcessName)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(connection.metadata.destinationDisplay)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.secondaryLabel)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: Theme.Spacing.xs) {
                tag(connection.metadata.network.uppercased())
                if !connection.metadata.type.isEmpty {
                    tag(connection.metadata.type.uppercased())
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Chain

    private func chainCard(for connection: ClashConnection) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader("代理链路", symbolName: "link")
                if connection.chains.isEmpty {
                    Text("—")
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.tertiaryLabel)
                } else {
                    // chains are outermost-first; show as inbound → … → exit.
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        ForEach(Array(connection.chains.enumerated()), id: \.offset) { index, hop in
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: index == connection.chains.count - 1
                                    ? "arrow.up.right.circle.fill"
                                    : "circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(index == connection.chains.count - 1
                                        ? Theme.Color.accent
                                        : Theme.Color.tertiaryLabel)
                                Text(hop)
                                    .font(Theme.Font.monoSmall)
                                    .foregroundStyle(Theme.Color.label)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Routing

    private func routingCard(for connection: ClashConnection) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader("路由与时序", symbolName: "arrow.triangle.branch")
                detailRow("规则", value: connection.rule.isEmpty ? "—" : connection.rule)
                detailRow("DNS 模式", value: connection.metadata.dnsMode.isEmpty
                    ? "—" : connection.metadata.dnsMode)
                detailRow("来源", value: sourceDisplay(for: connection))
                detailRow("开始", value: startDisplay(for: connection))
                detailRow("时长", value: DurationFormatter.ageString(
                    sinceRFC3339: connection.start, now: now))
            }
        }
    }

    // MARK: Traffic

    private func trafficCard(for connection: ClashConnection) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader("流量", symbolName: "arrow.up.arrow.down")
                HStack(spacing: Theme.Spacing.xl) {
                    MetricView(
                        value: ByteFormatter.string(fromBytes: connection.upload),
                        caption: "上传",
                        symbolName: "arrow.up",
                        tint: Theme.Color.upload
                    )
                    MetricView(
                        value: ByteFormatter.string(fromBytes: connection.download),
                        caption: "下载",
                        symbolName: "arrow.down",
                        tint: Theme.Color.download
                    )
                }
            }
        }
    }

    // MARK: Pieces

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.label)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption2.weight(.semibold))
            .foregroundStyle(Theme.Color.secondaryLabel)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, 2)
            .background(Theme.Color.hover, in: Capsule())
    }

    private func sourceDisplay(for connection: ClashConnection) -> String {
        let ip = connection.metadata.sourceIP
        let port = connection.metadata.sourcePort
        if ip.isEmpty { return port.isEmpty ? "—" : ":\(port)" }
        return port.isEmpty ? ip : "\(ip):\(port)"
    }

    private func startDisplay(for connection: ClashConnection) -> String {
        guard let date = DurationFormatter.date(fromRFC3339: connection.start) else {
            return "—"
        }
        return date.formatted(date: .omitted, time: .standard)
    }
}

// =============================================================================
// MARK: - Sort keys & display helpers
// =============================================================================

/// Comparable key paths backing the Table's sortable columns, plus the display
/// helpers shared by the table cells and the inspector. `start` is an RFC 3339
/// string on the wire, so the time column sorts on a parsed `Date`
/// (unparseable timestamps sort as `.distantPast`); the process and chain
/// columns sort on the same friendly strings the cells render.
extension ClashConnection {
    /// Parsed start time for chronological sorting; `.distantPast` when the
    /// timestamp can't be parsed so such rows sink to the bottom newest-first.
    var startDate: Date {
        DurationFormatter.date(fromRFC3339: start) ?? .distantPast
    }

    /// A friendly executable name from the (possibly empty) process path,
    /// stripping a trailing `(user)` annotation sing-box sometimes appends.
    /// Returns `"—"` when the process is unknown.
    var friendlyProcessName: String {
        let raw = metadata.processPath
        guard !raw.isEmpty else { return "—" }
        // Drop a trailing " (user)" style suffix before taking the last path
        // component so we show the executable name, not the annotation.
        let path = raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? raw
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? raw : name
    }

    /// The friendly executable name used by the 进程 column, for case-insensitive
    /// alphabetical sorting that matches what the user sees.
    var processSortKey: String {
        let name = friendlyProcessName
        return name == "—" ? "" : name.lowercased()
    }

    /// The proxy the connection actually exits through. `chains` is outermost
    /// first, so the exit node is the last entry (e.g. the selected node tag).
    var exitNodeDisplay: String {
        chains.last ?? "—"
    }

    /// The exit-node tag used by the 链路 column, for alphabetical sorting.
    var chainSortKey: String {
        (chains.last ?? "").lowercased()
    }
}
