import LinkoKit
import SwiftUI

/// The 概览 (Overview) surface: at-a-glance status cards (core, selected node,
/// system proxy), the live up/down throughput, cumulative totals, and the
/// active connection count — the dashboard's "is everything healthy?" view.
struct OverviewView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var viewModel: DashboardViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.md)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                statusGrid
                if appState.isCoreRunning {
                    liveThroughput
                    totalsCard
                } else {
                    stoppedNotice
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Stopped notice

    /// Replaces the live-rate and totals cards with a single quiet card when the
    /// core is stopped, so the overview doesn't render a wall of zeros. Mirrors
    /// the `DashboardEmptyState` idiom used by the other dashboard sections.
    private var stoppedNotice: some View {
        Card {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "speedometer")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Theme.Color.tertiaryLabel)
                VStack(alignment: .leading, spacing: 2) {
                    Text("核心未运行")
                        .font(Theme.Font.heading)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                    Text("开启系统代理后，这里会显示实时速率与累计流量。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.tertiaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Status grid

    private var statusGrid: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
            statusCard(
                title: "核心状态",
                symbolName: "cpu",
                kind: coreStatusKind,
                primary: coreStatusTitle,
                secondary: coreStatusDetail
            )
            statusCard(
                title: "当前节点",
                symbolName: "antenna.radiowaves.left.and.right",
                kind: appState.selectedNode == nil ? .inactive : .active,
                primary: appState.selectedNode?.name ?? "未选择",
                secondary: nodeDetail
            )
            statusCard(
                title: "系统代理",
                symbolName: "network",
                kind: appState.isSystemProxyEnabled ? .active : .inactive,
                primary: appState.isSystemProxyEnabled ? "已开启" : "已关闭",
                secondary: "混合端口 \(appState.preferences.mixedPort)"
            )
        }
    }

    private func statusCard(
        title: String,
        symbolName: String,
        kind: StatusKind,
        primary: String,
        secondary: String
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Color.accent)
                    Text(title)
                        .font(Theme.Font.caption.weight(.medium))
                        .foregroundStyle(Theme.Color.secondaryLabel)
                    Spacer(minLength: 0)
                    Circle()
                        .fill(kind.color)
                        .frame(width: 8, height: 8)
                }
                Text(primary)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(secondary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Live throughput

    private var liveThroughput: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader("实时速率", symbolName: "speedometer") {
                    CountBadge(count: viewModel.connectionCount)
                }
                HStack(spacing: Theme.Spacing.xxl) {
                    MetricView(
                        value: ByteFormatter.rateString(bytesPerSecond: viewModel.currentDownRate),
                        caption: "下载",
                        symbolName: "arrow.down",
                        tint: Theme.Color.download
                    )
                    MetricView(
                        value: ByteFormatter.rateString(bytesPerSecond: viewModel.currentUpRate),
                        caption: "上传",
                        symbolName: "arrow.up",
                        tint: Theme.Color.upload
                    )
                    Spacer(minLength: 0)
                    MetricView(
                        value: "\(viewModel.connectionCount)",
                        caption: "活跃连接",
                        symbolName: "point.3.connected.trianglepath.dotted",
                        tint: Theme.Color.accent
                    )
                }
            }
        }
    }

    // MARK: - Totals

    private var totalsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader("累计流量", symbolName: "sum")
                HStack(spacing: Theme.Spacing.xxl) {
                    MetricView(
                        value: ByteFormatter.string(fromBytes: viewModel.totalDown),
                        caption: "累计下载",
                        symbolName: "arrow.down.circle",
                        tint: Theme.Color.download
                    )
                    MetricView(
                        value: ByteFormatter.string(fromBytes: viewModel.totalUp),
                        caption: "累计上传",
                        symbolName: "arrow.up.circle",
                        tint: Theme.Color.upload
                    )
                    Spacer(minLength: 0)
                    if viewModel.memory > 0 {
                        MetricView(
                            value: ByteFormatter.string(fromBytes: Int64(clamping: viewModel.memory)),
                            caption: "核心内存",
                            symbolName: "memorychip",
                            tint: Theme.Color.info
                        )
                    }
                }
            }
        }
    }

    // MARK: - Derived display

    private var coreStatusKind: StatusKind {
        switch appState.coreState {
        case .running: return .active
        case .stopped: return .inactive
        case .failed: return .error
        }
    }

    private var coreStatusTitle: String {
        switch appState.coreState {
        case .running: return "运行中"
        case .stopped: return "未运行"
        case .failed: return "启动失败"
        }
    }

    private var coreStatusDetail: String {
        switch appState.coreState {
        case .running(let pid): return "PID \(pid)"
        case .stopped: return "开启系统代理以启动"
        case .failed(let reason): return reason
        }
    }

    private var nodeDetail: String {
        guard let node = appState.selectedNode else { return "请先导入订阅" }
        return "\(node.protocolType.rawValue.uppercased()) · \(node.server):\(node.port)"
    }
}
