import AppKit
import LinkoKit
import SwiftUI

/// Content of the menu-style `MenuBarExtra`: status header, system proxy
/// toggle, node selector with delay badges, and app actions.
struct MenuContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            statusSection
            Divider()
            Toggle("系统代理", isOn: systemProxyBinding)
                .disabled(appState.isSwitchingProxy)
            Divider()
            nodeSection
            binaryHintSection
            Divider()
            actionSection
            Divider()
            Button("退出") {
                // AppDelegate.applicationWillTerminate restores the system
                // proxy and stops the core.
                NSApp.terminate(nil)
            }
        }
        .onAppear {
            appState.refreshCoreState()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        Text(statusText)
        if case .failed(let reason) = appState.coreState {
            Text(reason)
        }
        if let message = appState.lastErrorMessage {
            Text(message)
        }
    }

    @ViewBuilder
    private var nodeSection: some View {
        if appState.allNodes.isEmpty {
            Text("暂无节点，请先导入订阅")
        } else {
            Picker("节点", selection: nodeSelectionBinding) {
                ForEach(appState.allNodes) { node in
                    Text(nodeTitle(for: node)).tag(Optional(node.id))
                }
            }
            .pickerStyle(.inline)
            Button(appState.isTestingDelays ? "测延迟中…" : "测延迟") {
                appState.testDelays()
            }
            .disabled(appState.isTestingDelays || !isCoreRunning)
        }
    }

    @ViewBuilder
    private var binaryHintSection: some View {
        if !appState.isBinaryAvailable {
            Divider()
            Text("未找到 sing-box：运行 scripts/fetch-singbox.sh 或 brew install sing-box")
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Button("导入订阅…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.importSubscription)
        }
        Button("设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }

    // MARK: - Bindings

    private var systemProxyBinding: Binding<Bool> {
        Binding(
            get: { appState.isSystemProxyEnabled },
            set: { enabled in
                Task { await appState.setSystemProxy(enabled: enabled) }
            }
        )
    }

    private var nodeSelectionBinding: Binding<UUID?> {
        Binding(
            get: { appState.preferences.selectedNodeID },
            set: { appState.selectNode(id: $0) }
        )
    }

    // MARK: - Helpers

    private var isCoreRunning: Bool {
        if case .running = appState.coreState { return true }
        return false
    }

    private var statusText: String {
        switch appState.coreState {
        case .stopped:
            return "○ 核心未运行"
        case .running(let pid):
            return "● 核心运行中 (PID \(pid))"
        case .failed:
            return "✕ 核心启动失败"
        }
    }

    private func nodeTitle(for node: ProxyNode) -> String {
        if let delay = appState.nodeDelays[node.id] {
            return "\(node.name) — \(delay) ms"
        }
        return node.name
    }
}
