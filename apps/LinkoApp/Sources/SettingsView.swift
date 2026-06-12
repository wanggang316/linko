import AppKit
import LinkoKit
import SwiftUI

/// The 设置 page (a dashboard sidebar pane, reached via the sidebar gear): a
/// grouped `Form` covering general toggles, local ports, the delay-test
/// endpoint, software update, and an about section. Changes are validated, then
/// persisted through `AppState.updatePreferences`.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            StatusSection()
            GeneralSection()
            PortsSection()
            DelayTestSection()
            UpdateSection()
            AboutSection()
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .frame(minWidth: 460, minHeight: 360)
    }
}

// =============================================================================
// MARK: - Status
// =============================================================================

/// Surfaces the most recent error / notice — including a blocked-at-pre-flight
/// config-validation failure — so a bad node or rule never fails silently.
/// Only renders when there's something to show; offers a one-tap dismiss.
private struct StatusSection: View {
    @EnvironmentObject private var appState: AppState

    private var isValidationFailure: Bool {
        if case .failed = appState.coreState { return true }
        return false
    }

    var body: some View {
        if let message = appState.lastErrorMessage, !message.isEmpty {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline)
                            .foregroundStyle(Theme.Color.label)
                        Text(message)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: isValidationFailure
                        ? "exclamationmark.shield.fill"
                        : "exclamationmark.triangle.fill")
                        .foregroundStyle(isValidationFailure ? Theme.Color.error : Theme.Color.warning)
                }

                Button("清除提示") {
                    appState.lastErrorMessage = nil
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Color.accent)
            } header: {
                Text("状态")
            }
        }
    }

    private var headline: String {
        isValidationFailure ? "配置校验未通过，已阻止启动" : "提示"
    }
}

// =============================================================================
// MARK: - General
// =============================================================================

/// App-level toggles. Currently the status-aware "launch at login" switch,
/// backed by `SMAppService.mainApp` through `AppState.setLaunchAtLogin`.
private struct GeneralSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var launchAtLogin = false

    var body: some View {
        Section {
            Toggle(isOn: launchBinding) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("开机自启")
                        Text("登录后自动启动 Linko 并驻留菜单栏")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "power")
                        .foregroundStyle(Theme.Color.accent)
                }
            }

            if appState.loginItemStatus == .requiresApproval {
                Label {
                    Text("需在系统设置中批准：系统设置 › 通用 › 登录项。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.Color.warning)
                }
            }
        } header: {
            Text("通用")
        }
        .onAppear(perform: syncFromStatus)
    }

    /// Drives the toggle off the live `SMAppService` status (so a flip in System
    /// Settings is reflected) while routing writes through `AppState`.
    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                appState.setLaunchAtLogin(newValue)
                syncFromStatus()
            }
        )
    }

    private func syncFromStatus() {
        switch appState.loginItemStatus {
        case .enabled, .requiresApproval:
            launchAtLogin = true
        case .notRegistered, .notFound:
            launchAtLogin = false
        }
    }
}

// =============================================================================
// MARK: - Ports
// =============================================================================

/// Mixed inbound + Clash API ports, each validated to 1–65535 and required to
/// differ. Edits are committed on field commit / stepper change. (Proxy-mode
/// selection moved to the overview's 网络接管 cards.)
private struct PortsSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var mixedPort = AppPreferences.default.mixedPort
    @State private var clashAPIPort = AppPreferences.default.clashAPIPort

    /// The mixed (HTTP/SOCKS) inbound only exists in system-proxy mode; TUN mode
    /// has no such listener, so its port is hidden there. The Clash API port is
    /// used in both modes (dashboard stats + control), so it always shows.
    private var showsMixedPort: Bool { appState.preferences.proxyMode == .systemProxy }

    private var portsConflict: Bool { showsMixedPort && mixedPort == clashAPIPort }

    var body: some View {
        Section {
            if showsMixedPort {
                PortField(
                    title: "混合端口",
                    help: "本地 HTTP / SOCKS 混合入站端口",
                    symbolName: "arrow.left.arrow.right",
                    value: $mixedPort,
                    onCommit: commit
                )
            }
            PortField(
                title: "Clash API 端口",
                help: "本地 Clash 兼容控制接口端口",
                symbolName: "antenna.radiowaves.left.and.right",
                value: $clashAPIPort,
                onCommit: commit
            )
            if portsConflict {
                Label("两个端口不能相同", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
            }
        } header: {
            Text("端口")
        } footer: {
            Text("修改端口会在代理开启时自动重启核心。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
        .onAppear(perform: load)
    }

    private func load() {
        mixedPort = appState.preferences.mixedPort
        clashAPIPort = appState.preferences.clashAPIPort
    }

    private func commit() {
        guard !portsConflict else { return }
        var preferences = appState.preferences
        guard preferences.mixedPort != mixedPort || preferences.clashAPIPort != clashAPIPort else { return }
        preferences.mixedPort = mixedPort
        preferences.clashAPIPort = clashAPIPort
        Task { await appState.updatePreferences(preferences) }
    }
}

/// A single labelled numeric port row: SF Symbol + title, a numeric text field
/// clamped to a valid port, and a stepper. Commits on blur / stepper tap.
private struct PortField: View {
    let title: String
    let help: String
    let symbolName: String
    @Binding var value: Int
    let onCommit: () -> Void

    @State private var text = ""

    private static let portRange = 1...65535

    var body: some View {
        LabeledContent {
            HStack(spacing: Theme.Spacing.xs) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.Font.mono)
                    .frame(width: 88)
                    .onSubmit(syncAndCommit)
                Stepper("", value: $value, in: Self.portRange)
                    .labelsHidden()
                    .onChange(of: value) { _, newValue in
                        text = String(newValue)
                        onCommit()
                    }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(help)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                }
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(Theme.Color.accent)
            }
        }
        .onAppear { text = String(value) }
        .onChange(of: text) { _, newValue in
            // Keep only digits so the field can never hold an invalid port.
            let digits = newValue.filter(\.isNumber)
            if digits != newValue { text = digits }
        }
    }

    private func syncAndCommit() {
        if let parsed = Int(text), Self.portRange.contains(parsed) {
            value = parsed
        }
        text = String(value)
        onCommit()
    }
}

// =============================================================================
// MARK: - Delay test
// =============================================================================

/// The URL used to measure per-node latency through the Clash API.
private struct DelayTestSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var delayTestURL = ""

    var body: some View {
        Section {
            LabeledContent {
                TextField("", text: $delayTestURL, prompt: Text(AppPreferences.default.delayTestURL))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.monoSmall)
                    .frame(minWidth: 220)
                    .onSubmit(commit)
            } label: {
                Label("延迟测试地址", systemImage: "timer")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Theme.Color.label)
                    .symbolRenderingMode(.monochrome)
                    .tint(Theme.Color.accent)
            }
        } header: {
            Text("测速")
        } footer: {
            Text("留空将恢复为默认地址。建议使用返回 204 的轻量端点。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
        .onAppear { delayTestURL = appState.preferences.delayTestURL }
    }

    private func commit() {
        let trimmed = delayTestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = trimmed.isEmpty ? AppPreferences.default.delayTestURL : trimmed
        guard appState.preferences.delayTestURL != newValue else { return }
        delayTestURL = newValue
        var preferences = appState.preferences
        preferences.delayTestURL = newValue
        Task { await appState.updatePreferences(preferences) }
    }
}

// =============================================================================
// MARK: - Software update
// =============================================================================

/// Sparkle update controls: a manual "检查更新…" trigger (disabled while a check
/// is already running) and the automatic-check toggle.
private struct UpdateSection: View {
    @ObservedObject private var updater = UpdaterController.shared

    @State private var autoCheck = UpdaterController.shared.automaticallyChecksForUpdates

    var body: some View {
        Section {
            LabeledContent {
                Button("检查更新…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("软件更新")
                        Text("从官方源获取最新版本")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Theme.Color.accent)
                }
            }

            Toggle(isOn: $autoCheck) {
                Label {
                    Text("自动检查更新")
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Theme.Color.accent)
                }
            }
            .onChange(of: autoCheck) { _, newValue in
                updater.automaticallyChecksForUpdates = newValue
            }
        } header: {
            Text("升级")
        }
    }
}

// =============================================================================
// MARK: - About
// =============================================================================

/// App identity: name + version.
private struct AboutSection: View {
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short, !build.isEmpty {
            return "\(short) (\(build))"
        }
        return short
    }

    var body: some View {
        Section {
            LabeledContent {
                Text(appVersion)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .textSelection(.enabled)
            } label: {
                Label("Linko", systemImage: "bolt.horizontal.circle.fill")
                    .tint(Theme.Color.accent)
            }
        } header: {
            Text("关于")
        }
    }
}
