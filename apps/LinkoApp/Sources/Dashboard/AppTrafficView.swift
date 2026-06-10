import LinkoKit
import SwiftUI

/// The 应用 (per-app traffic) surface: a native sortable `Table` that rolls every
/// live connection up by originating process into one row per app, with columns
/// for the app/process, cumulative upload, cumulative download, and the active
/// connection count. This beats Surge's per-app view by being native, sortable,
/// and live — driven entirely by `DashboardViewModel.appTrafficStats`, which the
/// view model recomputes from each `/connections` frame via `AppTrafficAggregator`
/// and clears when the core stops.
///
/// Columns are click-to-sort (default: most traffic first, matching the
/// aggregator's own ordering). A header summary keeps the total app count and a
/// combined up/down readout in view. Empty (no attributed traffic) and stopped
/// (core down) states stay crafted via `DashboardEmptyState`, matching the other
/// observability panes.
struct AppTrafficView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var viewModel: DashboardViewModel

    /// Drives the table's selection so a clicked row can be highlighted; no
    /// detail inspector is needed here since a row already carries every field.
    @State private var selection: AppTrafficStat.ID?
    /// Column sort order. Defaults to descending total bytes — the same ordering
    /// `AppTrafficAggregator` emits — so the busiest app stays on top until the
    /// user clicks another column header.
    @State private var sortOrder: [KeyPathComparator<AppTrafficStat>] = [
        KeyPathComparator(\.totalBytes, order: .reverse)
    ]

    /// The per-app rows sorted by the active column order. The view model's
    /// published array is already aggregated; the view only re-sorts.
    private var sortedStats: [AppTrafficStat] {
        viewModel.appTrafficStats.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if !appState.isCoreRunning {
                DashboardEmptyState(
                    symbolName: "app.dashed",
                    title: "核心未运行",
                    message: "开启系统代理后，这里会按应用汇总实时流量。"
                )
            } else if viewModel.appTrafficStats.isEmpty {
                DashboardEmptyState(
                    symbolName: "square.stack.3d.up.slash",
                    title: "暂无应用流量",
                    message: "当有应用经过代理产生流量时，会在这里按进程汇总。"
                )
            } else {
                VStack(spacing: 0) {
                    summaryBar
                    Divider()
                    appTable
                }
            }
        }
    }

    // MARK: - Summary

    /// A thin header summarizing how many apps are active and the combined
    /// up/down across all of them, so the per-app totals always have context.
    private var summaryBar: some View {
        let stats = viewModel.appTrafficStats
        let totalUp = stats.reduce(Int64(0)) { $0 &+ $1.upload }
        let totalDown = stats.reduce(Int64(0)) { $0 &+ $1.download }
        let totalConnections = stats.reduce(0) { $0 + $1.connectionCount }
        return HStack(spacing: Theme.Spacing.md) {
            SectionHeader("应用流量", symbolName: "square.grid.3x3.fill") {
                CountBadge(count: stats.count)
            }
            Spacer(minLength: Theme.Spacing.sm)
            summaryChip(
                symbol: "arrow.up",
                text: ByteFormatter.string(fromBytes: totalUp),
                tint: Theme.Color.upload
            )
            summaryChip(
                symbol: "arrow.down",
                text: ByteFormatter.string(fromBytes: totalDown),
                tint: Theme.Color.download
            )
            summaryChip(
                symbol: "point.3.connected.trianglepath.dotted",
                text: "\(totalConnections)",
                tint: Theme.Color.secondaryLabel
            )
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func summaryChip(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(text)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - Table

    private var appTable: some View {
        Table(sortedStats, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("应用 / 进程", value: \.processName) { stat in
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "app.fill")
                        .font(.body)
                        .foregroundStyle(Theme.Color.accent)
                        .frame(width: 18, alignment: .center)
                    Text(stat.processName)
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(Theme.Color.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(stat.processPath)
                }
            }
            .width(min: 150, ideal: 200)

            TableColumn("上传", value: \.upload) { stat in
                Text(ByteFormatter.string(fromBytes: stat.upload))
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.upload)
            }
            .width(min: 72, ideal: 90, max: 120)

            TableColumn("下载", value: \.download) { stat in
                Text(ByteFormatter.string(fromBytes: stat.download))
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.download)
            }
            .width(min: 72, ideal: 90, max: 120)

            TableColumn("活跃连接", value: \.connectionCount) { stat in
                Text("\(stat.connectionCount)")
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
            .width(min: 64, ideal: 78, max: 100)
        }
        .tableStyle(.inset)
    }
}
