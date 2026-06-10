import AppKit
import LinkoKit
import SwiftUI

/// Native macOS Settings scene: a grouped `Form` covering local ports, the
/// sing-box core binary, the delay-test endpoint, and an about section.
/// Changes are validated, then persisted through `AppState.updatePreferences`.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            StatusSection()
            GeneralSection()
            ModeSection()
            PortsSection()
            CoreSection()
            DelayTestSection()
            AboutSection()
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .environmentObject(appState)
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
// MARK: - Proxy mode
// =============================================================================

/// Selects how traffic is intercepted: the local system proxy (M1) or TUN
/// global mode (M2, runs inside a NetworkExtension system extension). Switching
/// modes while the proxy is on tears down the old mode and brings up the new
/// one through `AppState.setProxyMode`.
private struct ModeSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Section {
            Picker(selection: modeBinding) {
                ForEach(ProxyMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("代理模式")
                        Text(modeDescription)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(Theme.Color.accent)
                }
            }
            .pickerStyle(.segmented)
            .disabled(appState.isSwitchingProxy)

            if appState.preferences.proxyMode == .tun {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("首次启用需在系统设置中批准扩展")
                            .foregroundStyle(Theme.Color.label)
                        Text("系统设置 › 通用 › 登录项与扩展 › 网络扩展。批准后 TUN 会接管全部网络流量，覆盖不走系统代理的应用。")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(Theme.Color.warning)
                }
            }
        } header: {
            Text("代理模式")
        } footer: {
            Text("切换模式会在代理开启时自动迁移当前连接。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    private var modeDescription: String {
        switch appState.preferences.proxyMode {
        case .systemProxy:
            return "仅接管遵循系统代理设置的应用"
        case .tun:
            return "虚拟网卡接管全部流量（全局）"
        }
    }

    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: { appState.preferences.proxyMode },
            set: { newMode in
                Task { await appState.setProxyMode(newMode) }
            }
        )
    }
}

// =============================================================================
// MARK: - Ports
// =============================================================================

/// Mixed inbound + Clash API ports, each validated to 1–65535 and required to
/// differ. Edits are committed on field commit / stepper change.
private struct PortsSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var mixedPort = AppPreferences.default.mixedPort
    @State private var clashAPIPort = AppPreferences.default.clashAPIPort

    private var portsConflict: Bool { mixedPort == clashAPIPort }

    var body: some View {
        Section {
            PortField(
                title: "混合端口",
                help: "本地 HTTP / SOCKS 混合入站端口",
                symbolName: "arrow.left.arrow.right",
                value: $mixedPort,
                onCommit: commit
            )
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
            Text("修改端口会在系统代理开启时自动重启核心。")
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
// MARK: - Core
// =============================================================================

/// sing-box binary: an override path with a file picker, plus a live discovery
/// status line that reflects what `AppState.locateSingBoxBinary()` resolves.
private struct CoreSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var overridePath = ""

    private var resolvedBinary: URL? { appState.locateSingBoxBinary() }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: Theme.Spacing.xs) {
                    TextField("自动发现", text: $overridePath)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.monoSmall)
                        .frame(minWidth: 180)
                        .onSubmit(commit)
                    Button("选择…", action: chooseBinary)
                    if !overridePath.isEmpty {
                        Button {
                            overridePath = ""
                            commit()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.Color.tertiaryLabel)
                        .help("清除并恢复自动发现")
                    }
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("sing-box 路径")
                        Text("留空则自动查找核心")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "cpu")
                        .foregroundStyle(Theme.Color.accent)
                }
            }

            discoveryStatus
        } header: {
            Text("内核")
        } footer: {
            Text("可运行 scripts/fetch-singbox.sh 或执行 brew install sing-box 安装核心。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
        .onAppear { overridePath = appState.preferences.singBoxBinaryPathOverride ?? "" }
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        if let binary = resolvedBinary {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已找到核心")
                        .foregroundStyle(Theme.Color.label)
                    Text(binary.path)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.Color.active)
            }
        } else {
            Label {
                Text("未找到 sing-box，请指定路径或安装核心后重试。")
                    .foregroundStyle(Theme.Color.secondaryLabel)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Color.warning)
            }
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.title = "选择 sing-box 可执行文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        if !overridePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (overridePath as NSString).expandingTildeInPath)
                .deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            overridePath = url.path
            commit()
        }
    }

    private func commit() {
        let trimmed = overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        guard appState.preferences.singBoxBinaryPathOverride != newValue else { return }
        var preferences = appState.preferences
        preferences.singBoxBinaryPathOverride = newValue
        Task { await appState.updatePreferences(preferences) }
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
// MARK: - About
// =============================================================================

/// App identity, license, and upstream attribution.
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

            LabeledContent {
                Text("GPL-3.0")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            } label: {
                Label("开源许可", systemImage: "doc.text")
                    .tint(Theme.Color.accent)
            }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("基于 sing-box 核心")
                        .foregroundStyle(Theme.Color.label)
                    Text("感谢 SagerNet/sing-box 提供的代理核心。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                }
            } icon: {
                Image(systemName: "shippingbox")
                    .foregroundStyle(Theme.Color.accent)
            }
        } header: {
            Text("关于")
        }
    }
}
