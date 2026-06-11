import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - DashboardSection
// =============================================================================

/// The surfaces selectable from the dashboard sidebar: four observability
/// sections plus three routing-management sections (rules / policy groups /
/// DNS). Each carries its own SF Symbol and Chinese title so the sidebar and
/// the detail toolbar stay in sync from a single source of truth.
enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case connections
    case traffic
    case apps
    case logs
    case profiles
    case networkSwitch
    case subscriptions
    case nodes
    case rules
    case policyGroups
    case dns

    var id: String { rawValue }

    /// Observability sections grouped under "监控".
    static let monitoringSections: [DashboardSection] = [.overview, .connections, .traffic, .apps, .logs]
    /// Profile-management sections grouped under "配置".
    static let profileSections: [DashboardSection] = [.profiles, .networkSwitch]
    /// Subscription/node sections grouped under "订阅".
    static let subscriptionSections: [DashboardSection] = [.subscriptions, .nodes]
    /// Routing-management sections grouped under "路由".
    static let routingSections: [DashboardSection] = [.rules, .policyGroups, .dns]

    /// Sections that own their own navigation title and toolbar (so the
    /// dashboard chrome must step aside): the routing panes plus 配置 / 订阅 / 节点.
    private static let selfChromedSections: [DashboardSection] =
        profileSections + subscriptionSections + routingSections

    /// Whether this section owns its own navigation title and toolbar.
    var isRoutingSection: Bool {
        Self.selfChromedSections.contains(self)
    }

    /// Sidebar / toolbar title (Chinese, matching the app's tone).
    var title: String {
        switch self {
        case .overview: return "概览"
        case .connections: return "连接"
        case .traffic: return "流量"
        case .apps: return "应用"
        case .logs: return "日志"
        case .profiles: return "配置"
        case .networkSwitch: return "网络环境"
        case .subscriptions: return "订阅"
        case .nodes: return "节点"
        case .rules: return "规则"
        case .policyGroups: return "策略组"
        case .dns: return "DNS"
        }
    }

    /// SF Symbol shown beside the title in the sidebar.
    var symbolName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .traffic: return "chart.xyaxis.line"
        case .apps: return "square.grid.3x3.fill"
        case .logs: return "text.alignleft"
        case .profiles: return "rectangle.stack"
        case .networkSwitch: return "wifi.router"
        case .subscriptions: return "antenna.radiowaves.left.and.right"
        case .nodes: return "point.3.connected.trianglepath.dotted"
        case .rules: return "arrow.triangle.branch"
        case .policyGroups: return "rectangle.3.group"
        case .dns: return "globe"
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
            // Routing sections own their navigation title and toolbar; the
            // observability sections share the dashboard chrome (title + live
            // rate indicator). Applying both would double the title bar, so we
            // only attach the dashboard chrome for monitoring surfaces.
            if selection.isRoutingSection {
                detail
            } else {
                detail
                    .navigationTitle(selection.title)
                    .toolbar { detailToolbar }
            }
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
                ForEach(DashboardSection.monitoringSections) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
            }
            Section("配置") {
                ForEach(DashboardSection.profileSections) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
            }
            Section("订阅") {
                ForEach(DashboardSection.subscriptionSections) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
            }
            Section("路由") {
                ForEach(DashboardSection.routingSections) { section in
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
        case .apps:
            AppTrafficView()
        case .logs:
            LogsView()
        case .profiles:
            ProfilesView()
        case .networkSwitch:
            NetworkSwitchView()
        case .subscriptions:
            SubscriptionsView()
        case .nodes:
            NodesView()
        case .rules:
            RulesView()
        case .policyGroups:
            PolicyGroupsView()
        case .dns:
            DNSSettingsView()
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
