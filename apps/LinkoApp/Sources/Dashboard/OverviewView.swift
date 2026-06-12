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
                networkTakeoverSection
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

    // MARK: - Network takeover (proxy mode + start)

    /// The primary control surface: one card per (mutually exclusive) proxy mode,
    /// each with a switch that turns that mode on — the overview's start button.
    private var networkTakeoverSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("网络接管")
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.accent)
            LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                ModeCard(mode: .systemProxy)
                ModeCard(mode: .tun)
            }
        }
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
                    Text("开启代理后，这里会显示实时速率与累计流量。")
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
        case .stopped: return "开启代理以启动"
        case .failed(let reason): return reason
        }
    }

    private var nodeDetail: String {
        guard let node = appState.selectedNode else { return "请先导入订阅" }
        return "\(node.protocolType.rawValue.uppercased()) · \(node.server):\(node.port)"
    }
}

// =============================================================================
// MARK: - ModeCard
// =============================================================================

/// A proxy-mode card with a switch that turns that mode on. The two modes are
/// mutually exclusive, so a card reads "on" only when it is *both* the active
/// mode and actually running; flipping one on migrates off the other.
private struct ModeCard: View {
    @EnvironmentObject private var appState: AppState

    let mode: ProxyMode

    /// This card's mode is the selected one *and* traffic is flowing.
    private var isOn: Bool {
        appState.preferences.proxyMode == mode && appState.isProxyActive
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: symbolName)
                        .font(.title3)
                        .foregroundStyle(Theme.Color.accent)
                        .frame(width: 24)
                    Text(mode.displayName)
                        .font(Theme.Font.heading)
                        .foregroundStyle(Theme.Color.label)
                    Spacer(minLength: Theme.Spacing.xs)
                    if appState.isSwitchingProxy {
                        ProgressView().controlSize(.small)
                    }
                    Toggle("", isOn: binding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Theme.Color.accent)
                        .disabled(appState.isSwitchingProxy)
                }
                Text(description)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statusLine
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(isOn ? StatusKind.active.color : StatusKind.inactive.color)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(Theme.Font.caption)
                .foregroundStyle(isOn ? Theme.Color.label : Theme.Color.tertiaryLabel)
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { enabled in
                Task {
                    if enabled {
                        await appState.activateMode(mode)
                    } else {
                        await appState.setSystemProxy(enabled: false)
                    }
                }
            }
        )
    }

    private var symbolName: String {
        switch mode {
        case .systemProxy: return "network"
        case .tun: return "point.3.filled.connected.trianglepath.dotted"
        }
    }

    private var description: String {
        switch mode {
        case .systemProxy: return "仅接管遵循系统代理设置的应用，兼容性最好。"
        case .tun: return "虚拟网卡接管全部流量，覆盖不遵循系统代理的应用。"
        }
    }

    private var statusText: String {
        guard isOn else { return "未启用" }
        switch mode {
        case .systemProxy: return "已接管系统网络"
        case .tun: return "已接管全部流量 · \(appState.tunnelStatus.linkoLabel)"
        }
    }
}
