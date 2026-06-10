import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - DashboardSection
// =============================================================================

/// The four observability surfaces selectable from the dashboard sidebar.
/// Each carries its own SF Symbol and Chinese title so the sidebar and the
/// detail toolbar stay in sync from a single source of truth.
enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case connections
    case traffic
    case logs

    var id: String { rawValue }

    /// Sidebar / toolbar title (Chinese, matching the app's tone).
    var title: String {
        switch self {
        case .overview: return "概览"
        case .connections: return "连接"
        case .traffic: return "流量"
        case .logs: return "日志"
        }
    }

    /// SF Symbol shown beside the title in the sidebar.
    var symbolName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .traffic: return "chart.xyaxis.line"
        case .logs: return "text.alignleft"
        }
    }
}

// =============================================================================
// MARK: - DashboardView
// =============================================================================

/// Root of the Dashboard window: a native `NavigationSplitView` with a sidebar
/// of observability sections and a detail pane that swaps to match the
/// selection. Drives `DashboardViewModel`'s stream lifecycle with the window.
struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var viewModel: DashboardViewModel

    @State private var selection: DashboardSection = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .navigationTitle(selection.title)
                .toolbar { detailToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            // Begin streaming when the window appears; the view model is a
            // no-op while the core is stopped and auto-subscribes when it
            // comes up, so this is safe to call unconditionally.
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("监控") {
                ForEach(DashboardSection.allCases) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    /// Persistent live/idle indicator pinned to the bottom of the sidebar so
    /// the user always knows whether the dashboard is receiving data.
    private var sidebarFooter: some View {
        HStack(spacing: Theme.Spacing.xs) {
            StatusPill(coreStatusTitle, kind: coreStatusKind)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview:
            OverviewView()
        case .connections:
            ConnectionsView()
        case .traffic:
            TrafficView()
        case .logs:
            LogsView()
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            liveRateIndicator
        }
    }

    /// A compact up/down rate readout shown in the unified toolbar across every
    /// section, so the live pulse of the connection is always visible.
    private var liveRateIndicator: some View {
        HStack(spacing: Theme.Spacing.sm) {
            rateChip(
                symbol: "arrow.down",
                rate: viewModel.currentDownRate,
                tint: Theme.Color.download
            )
            rateChip(
                symbol: "arrow.up",
                rate: viewModel.currentUpRate,
                tint: Theme.Color.upload
            )
        }
        .opacity(appState.isCoreRunning ? 1 : 0.4)
    }

    private func rateChip(symbol: String, rate: Int64, tint: Color) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(ByteFormatter.rateString(bytesPerSecond: rate))
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - Core status mapping

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
        case .failed: return "已停止"
        }
    }
}
