import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - NodeDetailView
// =============================================================================

/// A read-only, grouped detail surface for a single `ProxyNode`. It renders the
/// fields that apply to the node's `protocolType` — including the protocol breadth
/// added this milestone: WireGuard's interface/peer parameters (carried on
/// `node.wireGuard`) and SSH's auth/host-key parameters (carried on `node.ssh`).
///
/// Editing proxy nodes is heavy (every protocol has its own credential/TLS/
/// transport shape, and nodes are normally minted from subscriptions), so this is
/// intentionally read-only: it makes WireGuard/SSH nodes legible — which key is
/// pinned, which address the tunnel uses, whether a pre-shared key or passphrase
/// is set — without claiming to be a node editor. Secrets (private keys,
/// passwords, pre-shared keys) are masked, never printed in the clear.
///
/// Usable standalone (e.g. in a popover/sheet) or embedded in a list detail pane;
/// `NodesView` hosts it as the detail of a node list.
struct NodeDetailView: View {
    let node: ProxyNode

    var body: some View {
        Form {
            generalSection

            switch node.protocolType {
            case .wireguard:
                if let wireGuard = node.wireGuard {
                    wireGuardInterfaceSection(wireGuard)
                    wireGuardPeerSection(wireGuard)
                } else {
                    missingDetailSection(
                        message: "该 WireGuard 节点缺少密钥参数，可能来自不完整的订阅。"
                    )
                }
            case .ssh:
                if let ssh = node.ssh {
                    sshAuthSection(ssh)
                    sshHostKeySection(ssh)
                } else {
                    missingDetailSection(
                        message: "该 SSH 节点缺少认证参数，可能来自不完整的订阅。"
                    )
                }
            case .shadowsocks, .vmess, .vless, .trojan, .hysteria2, .tuic:
                credentialsSection
                if showsTLSSection { tlsSection }
                if node.transport.type != .tcp { transportSection }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(node.name)
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            DetailRow(label: "名称", value: node.name)
            DetailRow(label: "协议", value: ProtocolPresentation.title(node.protocolType))
            DetailRow(label: "地址", value: node.server, mono: true)
            DetailRow(label: "端口", value: "\(node.port)", mono: true)
        } header: {
            Label("基本信息", systemImage: ProtocolPresentation.symbol(node.protocolType))
        }
    }

    // MARK: - Generic protocol credentials (ss/vmess/vless/trojan/hysteria2/tuic)

    private var credentialsSection: some View {
        Section("凭据") {
            if let uuid = node.uuid, !uuid.isEmpty {
                DetailRow(label: "UUID", value: uuid, mono: true, secret: true)
            }
            if let method = node.method, !method.isEmpty {
                DetailRow(label: "加密方式", value: method, mono: true)
            }
            if node.password != nil {
                DetailRow(label: "密码", value: SecretText.masked, mono: true)
            }
            if let flow = node.flow, !flow.isEmpty {
                DetailRow(label: "Flow", value: flow, mono: true)
            }
            if let alterId = node.alterId {
                DetailRow(label: "alterId", value: "\(alterId)", mono: true)
            }
            if let plugin = node.plugin, !plugin.isEmpty {
                DetailRow(label: "插件", value: plugin, mono: true)
            }
        }
    }

    /// TLS is worth surfacing when explicitly enabled or when a server name /
    /// Reality config is present (protocols that mandate TLS still carry these).
    private var showsTLSSection: Bool {
        node.tls.enabled
            || node.tls.serverName != nil
            || node.tls.reality != nil
            || node.tls.utlsFingerprint != nil
    }

    private var tlsSection: some View {
        Section("TLS") {
            DetailRow(label: "状态", value: node.tls.enabled ? "已启用" : "随协议启用")
            if let sni = node.tls.serverName, !sni.isEmpty {
                DetailRow(label: "SNI", value: sni, mono: true)
            }
            DetailRow(label: "跳过证书校验", value: node.tls.insecure ? "是" : "否")
            if !node.tls.alpn.isEmpty {
                DetailRow(label: "ALPN", value: node.tls.alpn.joined(separator: ", "), mono: true)
            }
            if let fingerprint = node.tls.utlsFingerprint {
                DetailRow(label: "uTLS 指纹", value: fingerprint.rawValue, mono: true)
            }
            if let reality = node.tls.reality {
                DetailRow(label: "Reality 公钥", value: reality.publicKey, mono: true, secret: true)
                if !reality.shortID.isEmpty {
                    DetailRow(label: "Reality short id", value: reality.shortID, mono: true)
                }
            }
        }
    }

    private var transportSection: some View {
        Section("传输") {
            DetailRow(label: "类型", value: node.transport.type.rawValue.uppercased(), mono: true)
            if let path = node.transport.path, !path.isEmpty {
                DetailRow(label: "路径", value: path, mono: true)
            }
            if !node.transport.host.isEmpty {
                DetailRow(label: "Host", value: node.transport.host.joined(separator: ", "), mono: true)
            }
            if let serviceName = node.transport.serviceName, !serviceName.isEmpty {
                DetailRow(label: "gRPC 服务名", value: serviceName, mono: true)
            }
        }
    }

    // MARK: - WireGuard

    private func wireGuardInterfaceSection(_ config: WireGuardConfig) -> some View {
        Section {
            DetailRow(
                label: "本地地址",
                value: config.localAddresses.isEmpty ? "—" : config.localAddresses.joined(separator: ", "),
                mono: true
            )
            DetailRow(label: "私钥", value: SecretText.maskedIfPresent(config.privateKey), mono: true)
            if let mtu = config.mtu {
                DetailRow(label: "MTU", value: "\(mtu)", mono: true)
            } else {
                DetailRow(label: "MTU", value: "默认 (1408)")
            }
        } header: {
            Label("WireGuard 接口", systemImage: "personalhotspot")
        } footer: {
            if config.localAddresses.isEmpty {
                Label("缺少本地地址，隧道将无法建立。", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
            }
        }
    }

    private func wireGuardPeerSection(_ config: WireGuardConfig) -> some View {
        Section("WireGuard 对端") {
            DetailRow(label: "端点", value: "\(node.server):\(node.port)", mono: true)
            DetailRow(label: "对端公钥", value: SecretText.maskedIfPresent(config.peerPublicKey), mono: true)
            if let preSharedKey = config.preSharedKey, !preSharedKey.isEmpty {
                DetailRow(label: "预共享密钥", value: SecretText.masked, mono: true)
            }
            if !config.reserved.isEmpty {
                DetailRow(
                    label: "Reserved",
                    value: config.reserved.prefix(3).map(String.init).joined(separator: ", "),
                    mono: true
                )
            }
            if let keepalive = config.persistentKeepalive, keepalive > 0 {
                DetailRow(label: "持久保活", value: "\(keepalive) 秒", mono: true)
            }
        }
    }

    // MARK: - SSH

    private func sshAuthSection(_ config: SSHConfig) -> some View {
        Section {
            DetailRow(label: "用户名", value: config.user.isEmpty ? "—" : config.user, mono: true)
            DetailRow(label: "认证方式", value: SSHPresentation.authMethod(config))
            if config.password != nil {
                DetailRow(label: "密码", value: SecretText.masked, mono: true)
            }
            if config.privateKey != nil {
                DetailRow(label: "私钥", value: "内联 PEM（已隐藏）", mono: true)
            }
            if let path = config.privateKeyPath, !path.isEmpty {
                DetailRow(label: "私钥路径", value: path, mono: true)
            }
            if config.privateKeyPassphrase != nil {
                DetailRow(label: "私钥口令", value: SecretText.masked, mono: true)
            }
            if let clientVersion = config.clientVersion, !clientVersion.isEmpty {
                DetailRow(label: "客户端版本", value: clientVersion, mono: true)
            }
        } header: {
            Label("SSH 认证", systemImage: "terminal")
        }
    }

    private func sshHostKeySection(_ config: SSHConfig) -> some View {
        Section {
            if config.hostKey.isEmpty {
                Label("未固定主机密钥（不校验服务器身份）", systemImage: "exclamationmark.shield")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
            } else {
                ForEach(Array(config.hostKey.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !config.hostKeyAlgorithms.isEmpty {
                DetailRow(
                    label: "算法",
                    value: config.hostKeyAlgorithms.joined(separator: ", "),
                    mono: true
                )
            }
        } header: {
            Label("主机密钥", systemImage: "lock.shield")
        }
    }

    // MARK: - Missing detail fallback

    private func missingDetailSection(message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// =============================================================================
// MARK: - DetailRow
// =============================================================================

/// A label/value row for a read-only detail form: the label trails to the left,
/// the value sits to the right (monospaced for keys/addresses/ports). The value
/// is text-selectable so a user can copy an address or pinned key.
private struct DetailRow: View {
    let label: String
    let value: String
    var mono = false
    /// When `true`, the value is a sensitive field shown already-masked; this
    /// just relaxes truncation so the mask reads cleanly.
    var secret = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(label)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.secondaryLabel)
            Spacer(minLength: Theme.Spacing.md)
            Text(value)
                .font(mono ? Theme.Font.monoSmall : Theme.Font.body)
                .foregroundStyle(Theme.Color.label)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(secret ? 1 : 2)
                .truncationMode(.middle)
        }
    }
}

// =============================================================================
// MARK: - Presentation helpers
// =============================================================================

/// Display strings + glyphs for a `NodeProtocol`, shared by the detail view and
/// the node list so the two never drift.
enum ProtocolPresentation {
    static func title(_ proto: NodeProtocol) -> String {
        switch proto {
        case .shadowsocks: return "Shadowsocks"
        case .vmess: return "VMess"
        case .vless: return "VLESS"
        case .trojan: return "Trojan"
        case .hysteria2: return "Hysteria2"
        case .tuic: return "TUIC"
        case .wireguard: return "WireGuard"
        case .ssh: return "SSH"
        }
    }

    static func symbol(_ proto: NodeProtocol) -> String {
        switch proto {
        case .shadowsocks: return "shield.lefthalf.filled"
        case .vmess, .vless: return "v.circle"
        case .trojan: return "lock.shield"
        case .hysteria2: return "bolt.horizontal"
        case .tuic: return "antenna.radiowaves.left.and.right"
        case .wireguard: return "personalhotspot"
        case .ssh: return "terminal"
        }
    }
}

/// SSH-specific presentation: a concise description of the auth method in use.
private enum SSHPresentation {
    static func authMethod(_ config: SSHConfig) -> String {
        if config.privateKey != nil || (config.privateKeyPath?.isEmpty == false) {
            return "私钥"
        }
        if config.password != nil {
            return "密码"
        }
        return "未配置"
    }
}

/// Helpers for masking secret values so credentials never render in the clear.
private enum SecretText {
    static let masked = "••••••••"

    /// Masks a non-empty secret, or shows a placeholder when it is empty.
    static func maskedIfPresent(_ value: String) -> String {
        value.isEmpty ? "—" : masked
    }
}
