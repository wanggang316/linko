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
    @Environment(\.openSettings) private var openSettings

    /// Self-contained traffic meter for the header rates, so the menu does not
    /// depend on the Dashboard view model being present in its environment.
    @StateObject private var meter = MenuTrafficMeter()

    /// Fixed popover width — tight, panel-like, never a sprawling menu.
    private let panelWidth: CGFloat = 320

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
                    Text("系统代理")
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
                .fill(appState.isSystemProxyEnabled ? Theme.Color.accent.opacity(0.12) : Theme.Color.hover.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(
                    appState.isSystemProxyEnabled ? Theme.Color.accent.opacity(0.3) : Theme.Color.cardBorder,
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
                if !appState.allNodes.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        CountBadge(count: appState.allNodes.count)
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
                        .disabled(appState.isTestingDelays || !isCoreRunning)
                    }
                }
            }

            if appState.allNodes.isEmpty {
                emptyNodeState
            } else {
                nodeList
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

    private var nodeList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(appState.allNodes) { node in
                    NodeRow(
                        node: node,
                        isSelected: node.id == appState.preferences.selectedNodeID,
                        delay: appState.nodeDelays[node.id]
                    ) {
                        appState.selectNode(id: node.id)
                    }
                }
            }
        }
        .frame(maxHeight: nodeListMaxHeight)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Caps the list around five rows; longer subscriptions scroll.
    private var nodeListMaxHeight: CGFloat {
        min(CGFloat(appState.allNodes.count) * 38, 200)
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
            FooterButton(symbolName: "gearshape", help: "设置") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
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
            get: { appState.isSystemProxyEnabled },
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
        return appState.isSystemProxyEnabled ? "已接管系统网络" : "未启用，流量直连"
    }

    private var proxyIconTint: Color {
        appState.isSystemProxyEnabled ? Theme.Color.accent : Theme.Color.inactive
    }

    private func rateText(_ bytesPerSecond: Int64) -> String {
        ByteFormatter.rateString(bytesPerSecond: bytesPerSecond)
    }
}

// =============================================================================
// MARK: - Node row
// =============================================================================

/// One selectable node entry: protocol glyph, name, server endpoint, latency
/// badge, and a checkmark when selected. Hover-highlighted, tap to select.
private struct NodeRow: View {
    let node: ProxyNode
    let isSelected: Bool
    let delay: Int?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Theme.Color.accent : Theme.Color.tertiaryLabel)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(Theme.Color.label)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.Font.caption2)
                        .foregroundStyle(Theme.Color.tertiaryLabel)
                        .lineLimit(1)
                }

                Spacer(minLength: Theme.Spacing.xs)
                DelayBadge(delay: delay)
            }
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.xs - 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(isSelected ? Theme.Color.accent.opacity(0.1) : Color.clear)
        )
        .hoverHighlight()
    }

    private var subtitle: String {
        "\(node.protocolType.rawValue.uppercased()) · \(node.server):\(node.port)"
    }
}

/// A latency chip colored by quality: green (fast), orange (medium), red (slow),
/// muted when untested.
private struct DelayBadge: View {
    let delay: Int?

    var body: some View {
        Group {
            if let delay {
                Text("\(delay) ms")
                    .font(Theme.Font.monoSmall.weight(.medium))
                    .foregroundStyle(tint(for: delay))
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(tint(for: delay).opacity(0.14), in: Capsule())
            } else {
                Text("—")
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }

    private func tint(for delay: Int) -> Color {
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
