import AppKit
import Combine
import LinkoKit
import SwiftUI

/// The menu bar popover surface, rendered as a real window-style panel
/// (`.menuBarExtraStyle(.window)`, configured in `LinkoApp.swift`) rather than a
/// default bulleted menu. It is a fixed-width control center: a status header
/// with live traffic rates, a prominent system-proxy switch, a scrollable node
/// list with latency badges, an inline binary-missing warning, and a footer of
/// icon actions (dashboard / import / settings / quit).
struct MenuContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    /// Self-contained traffic meter for the header rates, so the menu does not
    /// depend on the Dashboard view model being present in its environment.
    @StateObject private var meter = MenuTrafficMeter()

    /// Fixed popover width — tight, panel-like, never a sprawling menu.
    private let panelWidth: CGFloat = 320

    /// Which node group's flyout is currently open, keyed by group (subscription
    /// id, or a sentinel for the manual group). At most one is open at a time so
    /// the side flyouts behave like native submenus.
    @State private var openGroupKey: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            header
            proxyToggle
            if !appState.isBinaryAvailable {
                binaryWarning
            }
            if let message = appState.lastErrorMessage {
                noticeBanner(message)
            }
            nodeSection
            footer
        }
        .padding(Theme.Spacing.md)
        .frame(width: panelWidth)
        .background(.regularMaterial)
        .onAppear {
            appState.refreshCoreState()
            meter.bind(to: appState)
        }
        .onDisappear { meter.unbind() }
    }

    // MARK: - Header

    private var header: some View {
        Card(padding: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.Color.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("linko")
                            .font(Theme.Font.heading)
                            .foregroundStyle(Theme.Color.label)
                        Text(coreSubtitle)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                    Spacer(minLength: Theme.Spacing.xs)
                    StatusPill(coreStatus.title, kind: coreStatus.kind)
                }

                Divider().opacity(0.5)

                HStack(spacing: Theme.Spacing.lg) {
                    MetricView(
                        value: rateText(meter.downRate),
                        caption: "下载",
                        symbolName: "arrow.down",
                        tint: Theme.Color.download
                    )
                    MetricView(
                        value: rateText(meter.upRate),
                        caption: "上传",
                        symbolName: "arrow.up",
                        tint: Theme.Color.upload
                    )
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - System proxy toggle

    private var proxyToggle: some View {
        Toggle(isOn: proxyToggleBinding) {
            HStack(spacing: Theme.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(proxyIconTint.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: "network")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(proxyIconTint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.preferences.proxyMode.displayName)
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(Theme.Color.label)
                    Text(proxyStateText)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                }
                Spacer(minLength: Theme.Spacing.xs)
                if appState.isSwitchingProxy {
                    // Occupy the same trailing slot as the switch so the row
                    // doesn't reflow while the proxy is being toggled.
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.Color.accent)
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(appState.isProxyActive ? Theme.Color.accent.opacity(0.12) : Theme.Color.hover.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(
                    appState.isProxyActive ? Theme.Color.accent.opacity(0.3) : Theme.Color.cardBorder,
                    lineWidth: 1
                )
        )
        .disabled(appState.isSwitchingProxy)
    }

    // MARK: - Binary warning

    private var binaryWarning: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("未找到 sing-box")
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.Color.label)
                Text("运行 scripts/fetch-singbox.sh，或 brew install sing-box，或在设置中指定路径。")
                    .font(Theme.Font.caption2)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Color.warning.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.Color.warning.opacity(0.25), lineWidth: 1)
        )
    }

    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "info.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.info)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Color.info.opacity(0.1))
        )
    }

    // MARK: - Node section

    @ViewBuilder
    private var nodeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionHeader("节点", symbolName: "point.3.connected.trianglepath.dotted") {
                HStack(spacing: Theme.Spacing.xs) {
                    if !appState.allNodes.isEmpty {
                        CountBadge(count: appState.allNodes.count)
                    }
                    // Per-group "延迟测试" lives inside each flyout now, so the
                    // header only carries an icon shortcut into the full node
                    // manager (the Dashboard's 节点 page).
                    Button {
                        appState.openWindow(id: WindowID.dashboard, using: { openWindow(id: $0) })
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                            .padding(.horizontal, Theme.Spacing.xxs)
                            .padding(.vertical, 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: Theme.Radius.small)
                    .help("管理节点")
                }
            }

            if appState.allNodes.isEmpty {
                emptyNodeState
            } else {
                nodeGroups
            }
        }
    }

    private var emptyNodeState: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(Theme.Color.tertiaryLabel)
            Text("暂无节点")
                .font(Theme.Font.caption.weight(.medium))
                .foregroundStyle(Theme.Color.secondaryLabel)
            Button("导入订阅…") {
                appState.openWindow(id: WindowID.importSubscription, using: { openWindow(id: $0) })
            }
            .buttonStyle(.borderless)
            .font(Theme.Font.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.md)
    }

    /// One row per node group — each subscription, then the manual nodes — whose
    /// node list flies out to the right (see `NodeGroupRow`). This replaces the
    /// old inline scroll list, which collapsed to zero height inside the
    /// self-sizing `MenuBarExtra(.window)` panel: a `ScrollView` reports a
    /// ~zero ideal height, and a `maxHeight` only caps it — it never forces the
    /// list open, so the rows were present but invisible. Moving the node list
    /// into a side flyout also keeps the panel itself compact.
    private var nodeGroups: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            ForEach(subscriptionGroups, id: \.id) { sub in
                NodeGroupRow(
                    title: sub.name,
                    nodes: sub.nodes,
                    canTestDelays: isCoreRunning,
                    isOpen: flyoutBinding(for: sub.id.uuidString)
                )
            }
            if !appState.manualNodes.isEmpty {
                NodeGroupRow(
                    title: "手动节点",
                    nodes: appState.manualNodes,
                    canTestDelays: isCoreRunning,
                    isOpen: flyoutBinding(for: Self.manualGroupKey)
                )
            }
        }
    }

    /// Sentinel key for the manual-nodes group (real groups key off the
    /// subscription's UUID string).
    private static let manualGroupKey = "__manual__"

    /// A mutually-exclusive open/closed binding for one group's side flyout:
    /// opening one closes any other, so only a single flyout is ever on screen.
    private func flyoutBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { openGroupKey == key },
            set: { isOpen in openGroupKey = isOpen ? key : (openGroupKey == key ? nil : openGroupKey) }
        )
    }

    /// Subscriptions that actually carry nodes, in profile order.
    private var subscriptionGroups: [LinkoKit.Subscription] {
        appState.subscriptions.filter { !$0.nodes.isEmpty }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.xs) {
            FooterButton(symbolName: "chart.bar.xaxis", help: "打开仪表盘") {
                appState.openWindow(id: WindowID.dashboard, using: { openWindow(id: $0) })
            }
            FooterButton(symbolName: "square.and.arrow.down", help: "导入订阅") {
                appState.openWindow(id: WindowID.importSubscription, using: { openWindow(id: $0) })
            }
            FooterButton(symbolName: "arrow.down.circle", help: "检查更新…") {
                NSApp.activate(ignoringOtherApps: true)
                UpdaterController.shared.checkForUpdates()
            }
            FooterButton(symbolName: "gearshape", help: "设置") {
                appState.pendingDashboardSection = .settings
                appState.openWindow(id: WindowID.dashboard, using: { openWindow(id: $0) })
            }
            Spacer(minLength: 0)
            FooterButton(symbolName: "power", help: "退出", tint: Theme.Color.error) {
                // AppDelegate.applicationWillTerminate restores the system proxy
                // and stops the core.
                NSApp.terminate(nil)
            }
        }
        .padding(.top, Theme.Spacing.xxs)
    }

    // MARK: - Bindings

    private var proxyToggleBinding: Binding<Bool> {
        Binding(
            get: { appState.isProxyActive },
            set: { enabled in
                Task { await appState.setSystemProxy(enabled: enabled) }
            }
        )
    }

    // MARK: - Derived state

    private var isCoreRunning: Bool {
        if case .running = appState.coreState { return true }
        return false
    }

    private var coreStatus: (title: String, kind: StatusKind) {
        switch appState.coreState {
        case .stopped: return ("未运行", .inactive)
        case .running: return ("运行中", .active)
        case .failed: return ("启动失败", .error)
        }
    }

    private var coreSubtitle: String {
        // In TUN mode the core runs inside the NetworkExtension (no app-side
        // PID); surface the tunnel status instead of a meaningless PID.
        if appState.preferences.proxyMode == .tun {
            switch appState.coreState {
            case .failed(let reason): return reason
            default: return "TUN 模式 · \(appState.tunnelStatus.linkoLabel)"
            }
        }
        switch appState.coreState {
        case .stopped:
            return "核心已停止"
        case .running(let pid):
            return "核心运行中 · PID \(pid)"
        case .failed(let reason):
            return reason
        }
    }

    private var proxyStateText: String {
        if appState.isSwitchingProxy { return "切换中…" }
        switch appState.preferences.proxyMode {
        case .systemProxy:
            return appState.isProxyActive ? "已接管系统网络" : "未启用，流量直连"
        case .tun:
            return appState.isProxyActive ? "TUN 已接管全部流量" : "未启用，流量直连"
        }
    }

    private var proxyIconTint: Color {
        appState.isProxyActive ? Theme.Color.accent : Theme.Color.inactive
    }

    private func rateText(_ bytesPerSecond: Int64) -> String {
        ByteFormatter.rateString(bytesPerSecond: bytesPerSecond)
    }
}

// =============================================================================
// MARK: - Node group menu
// =============================================================================

/// One node group rendered as a Surge-style flyout: a compact panel row (group
/// name + the node selected within it + a chevron) whose node list flies out to
/// the **right** of the row in a popover — not a downward pull-down menu. The
/// popover lists the group's nodes with a checkmark on the active one, each
/// labeled with its latency, plus a "延迟测试" action. Selecting a node sets the
/// active node for the whole profile (linko has a single `proxy` selector), so
/// only the group that owns the active node shows a selection in its row.
///
/// Why a popover instead of `Menu`: a SwiftUI `Menu` renders an AppKit pull-down
/// that drops *down* from the row with no public way to steer it sideways, so
/// the `chevron.right` promised a side flyout the menu never delivered. A
/// `.popover(arrowEdge: .trailing)` escapes the self-sizing `MenuBarExtra(.window)`
/// panel bounds and emerges from the row's trailing edge (the system flips it to
/// the leading side only when the screen edge leaves no room), and — unlike the
/// panel itself — gives its `ScrollView` a real height, so long node lists scroll.
private struct NodeGroupRow: View {
    @EnvironmentObject private var appState: AppState

    let title: String
    let nodes: [ProxyNode]
    /// Whether the Clash API is live, so a delay test can run.
    let canTestDelays: Bool
    /// Drives this group's side flyout; mutually exclusive across groups.
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            rowLabel
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.Radius.small)
        .popover(isPresented: $isOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            NodeFlyoutList(title: title, nodes: nodes, canTestDelays: canTestDelays)
                .environmentObject(appState)
        }
    }

    /// The node in this group that is currently active, if any.
    private var currentNode: ProxyNode? {
        nodes.first { $0.id == appState.preferences.selectedNodeID }
    }

    private var rowLabel: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.bodyEmphasized)
                .foregroundStyle(Theme.Color.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.xs)
            Text(currentNode?.name ?? "未选择")
                .font(Theme.Font.caption)
                .foregroundStyle(currentNode != nil ? Theme.Color.accent : Theme.Color.tertiaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.right")
                .font(Theme.Font.caption2)
                .foregroundStyle(isOpen ? Theme.Color.accent : Theme.Color.tertiaryLabel)
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xs - 1)
        .contentShape(Rectangle())
    }
}

// =============================================================================
// MARK: - Node flyout list
// =============================================================================

/// The side flyout for one node group: a compact "延迟测试" header followed by a
/// scrollable list of the group's nodes, each with a leading checkmark on the
/// active one, its name, and its measured latency. Tapping a node selects it for
/// the whole profile and dismisses the flyout.
private struct NodeFlyoutList: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let title: String
    let nodes: [ProxyNode]
    let canTestDelays: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(nodes) { node in
                        nodeRow(node)
                    }
                }
                .padding(Theme.Spacing.xs)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: 380)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.xs)
            Button {
                appState.testDelays()
            } label: {
                HStack(spacing: Theme.Spacing.xxs) {
                    if appState.isTestingDelays {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "bolt.fill").font(.caption2)
                    }
                    Text("测延迟").font(Theme.Font.caption)
                }
            }
            .buttonStyle(.borderless)
            .disabled(appState.isTestingDelays || !canTestDelays)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func nodeRow(_ node: ProxyNode) -> some View {
        let isSelected = node.id == appState.preferences.selectedNodeID
        return Button {
            appState.selectNode(id: node.id)
            dismiss()
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Color.accent)
                    .frame(width: 14)
                    .opacity(isSelected ? 1 : 0)
                Text(node.name)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.xs)
                if let delay = appState.nodeDelays[node.id] {
                    Text("\(delay) ms")
                        .font(Theme.Font.caption.monospacedDigit())
                        .foregroundStyle(latencyTint(delay))
                }
            }
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.xs - 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.Radius.small)
    }

    /// Green / amber / red latency tint: fast (< 200 ms) / usable / slow.
    private func latencyTint(_ delay: Int) -> Color {
        switch delay {
        case ..<200: return Theme.Color.active
        case ..<500: return Theme.Color.warning
        default: return Theme.Color.error
        }
    }
}

// =============================================================================
// MARK: - Footer button
// =============================================================================

/// A square icon button for the footer action row, with a hover highlight and
/// a native help tooltip.
private struct FooterButton: View {
    let symbolName: String
    let help: String
    var tint: Color = Theme.Color.secondaryLabel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.Radius.small)
        .help(help)
    }
}

// =============================================================================
// MARK: - Menu traffic meter
// =============================================================================

/// A tiny, self-contained traffic subscriber for the header rate display. It
/// mirrors the dashboard's `/traffic` stream but lives entirely inside the menu
/// so the popover header shows live rates without depending on the Dashboard
/// view model being injected. Subscribes only while the core is running and the
/// popover is open; tears the socket down on disappear.
@MainActor
final class MenuTrafficMeter: ObservableObject {
    @Published private(set) var downRate: Int64 = 0
    @Published private(set) var upRate: Int64 = 0

    /// Initial reconnect backoff after the `/traffic` socket drops while the
    /// core is still running; doubles up to `maxReconnectDelay`.
    private static let initialReconnectDelay: Duration = .seconds(1)
    /// Upper bound on the reconnect backoff.
    private static let maxReconnectDelay: Duration = .seconds(10)

    private weak var appState: AppState?
    private var streamTask: Task<Void, Never>?
    private var coreStateObservation: AnyCancellable?

    func bind(to appState: AppState) {
        self.appState = appState
        observeCoreState()
        if appState.isCoreRunning { subscribe() }
    }

    func unbind() {
        coreStateObservation = nil
        streamTask?.cancel()
        streamTask = nil
        downRate = 0
        upRate = 0
    }

    deinit {
        streamTask?.cancel()
    }

    private func observeCoreState() {
        coreStateObservation = appState?.$coreState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .running:
                    if self.streamTask == nil { self.subscribe() }
                case .stopped, .failed:
                    self.streamTask?.cancel()
                    self.streamTask = nil
                    self.downRate = 0
                    self.upRate = 0
                }
            }
    }

    /// Subscribes to `/traffic` with transparent, bounded-backoff reconnect: a
    /// dropped socket while the core is still running is retried (so a transient
    /// clash-API hiccup doesn't freeze the header rate), while a genuinely
    /// stopped core bails and lets `observeCoreState` resubscribe later.
    private func subscribe() {
        streamTask = Task { [weak self] in
            var delay = Self.initialReconnectDelay
            while !Task.isCancelled {
                guard let self, let appState = self.appState, appState.isCoreRunning else { return }
                let api = appState.makeClashAPIClient()
                do {
                    for try await tick in api.trafficStream() {
                        self.downRate = tick.down
                        self.upRate = tick.up
                    }
                    delay = Self.initialReconnectDelay
                } catch {
                    // Socket closed/errored; fall through to the backoff below.
                }
                guard !Task.isCancelled, self.appState?.isCoreRunning == true else { return }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return // Cancelled during the backoff sleep.
                }
                delay = min(delay * 2, Self.maxReconnectDelay)
            }
        }
    }
}
