import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - DashboardSection
// =============================================================================

/// The surfaces selectable from the dashboard sidebar: four observability
/// sections plus three routing-management sections (rules / policy groups /
/// DNS). Each carries its own icon and Chinese title so the sidebar and
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
    case settings

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
    /// dashboard chrome must step aside): the routing panes plus 配置 / 订阅 /
    /// 节点, and the 设置 page (reached from the sidebar gear, not a group).
    private static let selfChromedSections: [DashboardSection] =
        profileSections + subscriptionSections + routingSections + [.settings]

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
        case .settings: return "设置"
        }
    }

    /// Sidebar icon: a colored tile with a white glyph, in the style of System
    /// Settings. 设置 has no sidebar row (the footer gear opens it); its style
    /// is here so that the switch covers every case.
    var iconStyle: SidebarIconTile.Style {
        switch self {
        case .overview: return .init("gauge.with.needle.fill", .blue)
        case .connections: return .init("arrow.left.arrow.right", .green)
        case .traffic: return .init("chart.bar.fill", .orange)
        case .apps: return .init("square.grid.2x2.fill", .purple)
        case .logs: return .init("text.alignleft", .gray)
        case .profiles: return .init("square.stack.3d.up.fill", .indigo)
        case .networkSwitch: return .init("wifi", size: 14, .teal)
        case .subscriptions: return .init("dot.radiowaves.up.forward", .red)
        case .nodes: return .init("server.rack", .graphite)
        case .rules: return .init("arrow.triangle.branch", .magenta)
        case .policyGroups: return .init("rectangle.3.group.fill", size: 14, .orange)
        case .dns: return .init("globe", .blue)
        case .settings: return .init("gearshape.fill", .gray)
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
            // Honor a deep-link requested before the window appeared (e.g. the
            // menu gear opening straight to 设置).
            consumePendingSection()
            // Begin streaming when the window appears; the view model is a
            // no-op while the core is stopped and auto-subscribes when it
            // comes up, so this is safe to call unconditionally.
            viewModel.start()
        }
        .onChange(of: appState.pendingDashboardSection) { _, _ in
            // Deep-link arriving while the window is already open.
            consumePendingSection()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    /// Applies and clears a pending section deep-link from `AppState`.
    private func consumePendingSection() {
        guard let pending = appState.pendingDashboardSection else { return }
        selection = pending
        appState.pendingDashboardSection = nil
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("监控") {
                ForEach(DashboardSection.monitoringSections) { section in
                    sidebarRow(section)
                }
            }
            Section("配置") {
                ForEach(DashboardSection.profileSections) { section in
                    sidebarRow(section)
                }
            }
            Section("订阅") {
                ForEach(DashboardSection.subscriptionSections) { section in
                    sidebarRow(section)
                }
            }
            Section("路由") {
                ForEach(DashboardSection.routingSections) { section in
                    sidebarRow(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    private func sidebarRow(_ section: DashboardSection) -> some View {
        Label {
            Text(section.title)
        } icon: {
            SidebarIconTile(style: section.iconStyle)
        }
        .tag(section)
    }

    /// Persistent live/idle indicator pinned to the bottom of the sidebar so
    /// the user always knows whether the dashboard is receiving data.
    private var sidebarFooter: some View {
        HStack(spacing: Theme.Spacing.xs) {
            StatusPill(coreStatusTitle, kind: coreStatusKind)
            Spacer(minLength: 0)
            Button {
                selection = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selection == .settings ? Theme.Color.accent : Theme.Color.secondaryLabel)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: Theme.Radius.small)
            .help("设置")
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
        case .settings:
            SettingsView()
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
        .padding(.horizontal, Theme.Spacing.sm)
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
