import LinkoKit
import SwiftUI

/// The 连接 (Connections) surface: a native `Table` of every live connection
/// with columns for process, destination, network, rule, proxy chain, byte
/// counts, and age. Columns are click-to-sort (default: newest first) via a
/// `sortOrder` binding. Supports closing a single connection (context menu) or
/// all of them (toolbar), plus an empty state when the core is stopped.
struct ConnectionsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var viewModel: DashboardViewModel

    /// Drives the table's selection; used to target the context-menu actions.
    @State private var selection: ClashConnection.ID?
    /// Column sort order. Defaults to newest-first (descending start date), the
    /// natural reverse-chronological view; clicking any sortable header rebinds
    /// it and shows the native sort-direction triangle.
    @State private var sortOrder: [KeyPathComparator<ClashConnection>] = [
        KeyPathComparator(\.startDate, order: .reverse)
    ]
    /// Re-evaluated once per second so the "时长" (age) column ticks live even
    /// when the snapshot itself hasn't changed.
    @State private var now = Date()

    private let ageTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The connections sorted by the current column order, recomputed as the
    /// snapshot or `sortOrder` changes. The view model no longer pre-sorts.
    private var sortedConnections: [ClashConnection] {
        viewModel.connections.sorted(using: sortOrder)
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
            }
        }
        .toolbar { toolbar }
        .onReceive(ageTimer) { now = $0 }
    }

    // MARK: - Table

    private var connectionsTable: some View {
        Table(sortedConnections, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("进程", value: \.processSortKey) { connection in
                Text(processName(for: connection))
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
                Text(chainDisplay(for: connection))
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
            if let id = ids.first {
                Button(role: .destructive) {
                    viewModel.closeConnection(id: id)
                } label: {
                    Label("关闭此连接", systemImage: "xmark.circle")
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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

    // MARK: - Cell formatting

    /// Extracts a friendly process name from the (possibly empty) process path,
    /// stripping a trailing `(user)` annotation sing-box sometimes appends.
    private func processName(for connection: ClashConnection) -> String {
        let raw = connection.metadata.processPath
        guard !raw.isEmpty else { return "—" }
        // Drop a trailing " (user)" style suffix before taking the last path
        // component so we show the executable name, not the annotation.
        let path = raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? raw
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? raw : name
    }

    /// The proxy the connection actually exits through. `chains` is outermost
    /// first, so the exit node is the last entry (e.g. the selected node tag).
    private func chainDisplay(for connection: ClashConnection) -> String {
        connection.chains.last ?? "—"
    }
}

// MARK: - Sort keys

/// Comparable key paths backing the Table's sortable columns. `start` is an
/// RFC 3339 string on the wire, so the time column sorts on a parsed `Date`
/// (unparseable timestamps sort as `.distantPast`); the process and chain
/// columns sort on the same friendly strings the cells render.
extension ClashConnection {
    /// Parsed start time for chronological sorting; `.distantPast` when the
    /// timestamp can't be parsed so such rows sink to the bottom newest-first.
    var startDate: Date {
        DurationFormatter.date(fromRFC3339: start) ?? .distantPast
    }

    /// The friendly executable name used by the 进程 column, for case-insensitive
    /// alphabetical sorting that matches what the user sees.
    var processSortKey: String {
        let raw = metadata.processPath
        guard !raw.isEmpty else { return "" }
        let path = raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? raw
        let name = (path as NSString).lastPathComponent
        return (name.isEmpty ? raw : name).lowercased()
    }

    /// The exit-node tag used by the 链路 column, for alphabetical sorting.
    var chainSortKey: String {
        (chains.last ?? "").lowercased()
    }
}
