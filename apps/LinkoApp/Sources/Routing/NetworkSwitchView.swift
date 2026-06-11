import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - NetworkSwitchView
// =============================================================================

/// The 网络环境 (network-based switching) surface: a master switch plus a list of
/// rules that map the current network — by IPv4 subnet (CIDR) or interface kind
/// — to a profile. When the active network matches a rule, linko switches to
/// that profile. This is the app-level realization of Surge's `SUBNET` policy
/// switching (sing-box has no such primitive), driven by `AppState`'s
/// permission-free `NetworkMonitor`.
struct NetworkSwitchView: View {
    @EnvironmentObject private var appState: AppState

    private var config: NetworkSwitchConfig { appState.networkSwitch }
    private var profiles: [ProfileSummary] { appState.profileSummaries }

    var body: some View {
        Form {
            masterSection
            currentNetworkSection
            if config.isEnabled {
                rulesSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("网络环境")
    }

    // MARK: - Master switch

    private var masterSection: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("按网络环境自动切换配置")
                        Text("根据当前所处网络（子网 / 接口）自动切换到对应配置档案。")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "wifi.router")
                        .foregroundStyle(Theme.Color.accent)
                }
            }
        } header: {
            Text("网络环境切换")
        } footer: {
            Text("例如：在家（192.168.1.0/24）用直连较多的档案，在公司有线网络用全局代理档案。规则自上而下匹配，命中即切换。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { config.isEnabled },
            set: { appState.setNetworkSwitchEnabled($0) }
        )
    }

    // MARK: - Current network

    private var currentNetworkSection: some View {
        Section {
            if let snapshot = appState.currentNetwork {
                LabeledContent {
                    Text(snapshot.interface.displayName)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                } label: {
                    Label("当前接口", systemImage: "antenna.radiowaves.left.and.right")
                }
                LabeledContent {
                    Text(snapshot.ipv4Addresses.isEmpty ? "无" : snapshot.ipv4Addresses.joined(separator: ", "))
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                        .textSelection(.enabled)
                } label: {
                    Label("本机 IPv4", systemImage: "number")
                }
            } else {
                Text("正在检测当前网络…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        } header: {
            Text("当前网络")
        } footer: {
            Text("用于参考：规则将与上面的接口 / IPv4 进行匹配。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        Section {
            if config.rules.isEmpty {
                Text("尚无规则。点击下方「添加规则」，把某个网络映射到一个配置档案。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
            ForEach(config.rules) { rule in
                NetworkSwitchRuleRow(
                    rule: rule,
                    profiles: profiles,
                    onChange: { appState.updateNetworkSwitchRule($0) },
                    onDelete: { appState.deleteNetworkSwitchRule(id: rule.id) }
                )
            }
            Button {
                addRule()
            } label: {
                Label("添加规则", systemImage: "plus")
            }
        } header: {
            Text("规则")
        } footer: {
            Text("子网：本机 IPv4 落在该 CIDR 内即匹配（如 192.168.1.0/24）。接口：默认路由走该类型网卡即匹配。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    private func addRule() {
        // Default to the active profile, and prefill a /24 derived from the
        // current network so the common "this Wi-Fi" rule is one edit away.
        let target = appState.activeProfileID
        let rule = NetworkSwitchRule(
            kind: .subnet,
            value: suggestedSubnet(),
            profileID: target
        )
        appState.addNetworkSwitchRule(rule)
    }

    /// A `/24` derived from the first local IPv4 (e.g. `192.168.1.42` →
    /// `192.168.1.0/24`), or empty when no address is known.
    private func suggestedSubnet() -> String {
        guard let ip = appState.currentNetwork?.ipv4Addresses.first else { return "" }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return "" }
        return "\(parts[0]).\(parts[1]).\(parts[2]).0/24"
    }
}

// =============================================================================
// MARK: - Rule row
// =============================================================================

/// One editable rule: match kind (子网 / 接口), its value, the target profile,
/// an enable toggle, and a delete button.
private struct NetworkSwitchRuleRow: View {
    let rule: NetworkSwitchRule
    let profiles: [ProfileSummary]
    let onChange: (NetworkSwitchRule) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Picker("", selection: kindBinding) {
                    Text("子网").tag(NetworkSwitchRule.Kind.subnet)
                    Text("接口").tag(NetworkSwitchRule.Kind.interface)
                }
                .labelsHidden()
                .frame(width: 90)

                valueControl

                Spacer()

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(rule.isEnabled ? "已启用" : "已停用")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Color.error)
            }

            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
                Picker("", selection: profileBinding) {
                    if profiles.isEmpty {
                        Text("无配置").tag(UUID())
                    }
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .opacity(rule.isEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var valueControl: some View {
        switch rule.kind {
        case .subnet:
            TextField("192.168.1.0/24", text: valueBinding)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.monoSmall)
                .frame(maxWidth: 200)
        case .interface:
            Picker("", selection: interfaceBinding) {
                ForEach(NetworkInterfaceKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
    }

    // MARK: Bindings

    private var kindBinding: Binding<NetworkSwitchRule.Kind> {
        Binding(
            get: { rule.kind },
            set: { newKind in
                var r = rule
                r.kind = newKind
                // Reset the value to a sensible default for the new kind so a
                // CIDR doesn't linger in an interface rule (and vice versa).
                switch newKind {
                case .subnet where !isCIDR(r.value):
                    r.value = ""
                case .interface where NetworkInterfaceKind(rawValue: r.value) == nil:
                    r.value = NetworkInterfaceKind.wifi.rawValue
                default:
                    break
                }
                onChange(r)
            }
        )
    }

    private var valueBinding: Binding<String> {
        Binding(get: { rule.value }, set: { var r = rule; r.value = $0; onChange(r) })
    }

    private var interfaceBinding: Binding<NetworkInterfaceKind> {
        Binding(
            get: { NetworkInterfaceKind(rawValue: rule.value) ?? .wifi },
            set: { var r = rule; r.value = $0.rawValue; onChange(r) }
        )
    }

    private var profileBinding: Binding<UUID> {
        Binding(get: { rule.profileID }, set: { var r = rule; r.profileID = $0; onChange(r) })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { rule.isEnabled }, set: { var r = rule; r.isEnabled = $0; onChange(r) })
    }

    private func isCIDR(_ s: String) -> Bool {
        s.contains("/") || s.contains(".")
    }
}
