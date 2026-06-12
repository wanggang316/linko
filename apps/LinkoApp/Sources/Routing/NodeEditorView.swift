import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - NodeEditorView
// =============================================================================

/// A protocol-aware form for creating or editing a *manual* node — the user's
/// own hand-added entry (subscription nodes stay read-only because a refresh
/// overwrites them; `NodeDetailView` renders those). It covers the six common
/// outbound protocols (Shadowsocks / VMess / VLESS / Trojan / Hysteria2 / TUIC),
/// each with its credentials and, where applicable, TLS and v2ray transport.
/// WireGuard and SSH are intentionally out of scope here (key-heavy, normally
/// imported), so the protocol picker never offers them.
///
/// The form edits a value-type `NodeDraft`; saving validates it and hands a
/// fully-formed `ProxyNode` back via `onSave`. Editing preserves the node's id,
/// so the caller can replace it in place.
struct NodeEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// The protocols this editor can mint. The node browser gates its
    /// "编辑 / 复制为可编辑节点" affordances on this set so a WireGuard/SSH node
    /// never reaches a form that cannot represent it. `nonisolated` so the
    /// value-type `NodeDraft` can consult it from its plain initializer.
    nonisolated static let supportedProtocols: [NodeProtocol] = [
        .shadowsocks, .vmess, .vless, .trojan, .hysteria2, .tuic,
    ]

    nonisolated static func supports(_ proto: NodeProtocol) -> Bool {
        supportedProtocols.contains(proto)
    }

    private let isEditing: Bool
    private let onSave: (ProxyNode) -> Void

    @State private var draft: NodeDraft
    @State private var validationError: String?

    /// `node == nil` ⇒ create mode; a non-nil node ⇒ edit mode (its id and any
    /// fields outside this editor's scope are preserved on save).
    init(node: ProxyNode? = nil, onSave: @escaping (ProxyNode) -> Void) {
        self.isEditing = node != nil
        self.onSave = onSave
        _draft = State(initialValue: NodeDraft(node: node))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                generalSection
                credentialsSection
                if draft.protocolType.supportsTLS { tlsSection }
                if draft.protocolType.supportsTransport { transportSection }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 460, height: 560)
        .background(.regularMaterial)
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            TextField("名称", text: $draft.name)
            Picker("协议", selection: $draft.protocolType) {
                ForEach(NodeEditorView.supportedProtocols, id: \.self) { proto in
                    Text(ProtocolPresentation.title(proto)).tag(proto)
                }
            }
            TextField("地址", text: $draft.server, prompt: Text("example.com 或 1.2.3.4"))
            TextField("端口", text: $draft.port, prompt: Text("443"))
        } header: {
            Label("基本信息", systemImage: ProtocolPresentation.symbol(draft.protocolType))
        }
    }

    // MARK: - Credentials (protocol-specific)

    @ViewBuilder
    private var credentialsSection: some View {
        Section("凭据") {
            switch draft.protocolType {
            case .shadowsocks:
                Picker("加密方式", selection: $draft.method) {
                    ForEach(NodeDraft.shadowsocksMethods, id: \.self) { method in
                        Text(method).tag(method)
                    }
                }
                TextField("密码", text: $draft.password)
                TextField("插件", text: $draft.plugin, prompt: Text("可选，如 obfs-local"))
                TextField("插件参数", text: $draft.pluginOpts, prompt: Text("可选，plugin_opts"))

            case .vmess:
                TextField("UUID", text: $draft.uuid)
                TextField("alterId", text: $draft.alterId, prompt: Text("0"))

            case .vless:
                TextField("UUID", text: $draft.uuid)
                TextField("Flow", text: $draft.flow, prompt: Text("可选，如 xtls-rprx-vision"))

            case .trojan, .hysteria2:
                TextField("密码", text: $draft.password)

            case .tuic:
                TextField("UUID", text: $draft.uuid)
                TextField("密码", text: $draft.password, prompt: Text("可选"))

            case .wireguard, .ssh:
                // Never reached: the protocol picker excludes these.
                Text("该协议暂不支持手动编辑")
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        }
    }

    // MARK: - TLS

    private var tlsSection: some View {
        Section {
            if draft.protocolType.mandatesTLS {
                LabeledContent("TLS", value: "随协议强制启用")
            } else {
                Toggle("启用 TLS", isOn: $draft.tlsEnabled)
            }

            if draft.tlsActive {
                TextField("SNI", text: $draft.sni, prompt: Text("可选，默认用地址"))
                Toggle("跳过证书校验", isOn: $draft.allowInsecure)
                TextField("ALPN", text: $draft.alpn, prompt: Text("可选，逗号分隔，如 h2,http/1.1"))
                Picker("uTLS 指纹", selection: $draft.utlsFingerprint) {
                    Text("无").tag(UTLSFingerprint?.none)
                    ForEach(UTLSFingerprint.allCases, id: \.self) { fp in
                        Text(fp.rawValue).tag(UTLSFingerprint?.some(fp))
                    }
                }
                TextField("Reality 公钥", text: $draft.realityPublicKey, prompt: Text("可选"))
                if !draft.realityPublicKey.isEmpty {
                    TextField("Reality short id", text: $draft.realityShortID, prompt: Text("可选"))
                }
            }
        } header: {
            Label("TLS", systemImage: "lock")
        }
    }

    // MARK: - Transport

    private var transportSection: some View {
        Section {
            Picker("类型", selection: $draft.transportType) {
                ForEach(TransportType.allCases, id: \.self) { type in
                    Text(NodeDraft.transportTitle(type)).tag(type)
                }
            }
            if draft.transportType != .tcp {
                if draft.transportType == .grpc {
                    TextField("gRPC 服务名", text: $draft.transportServiceName, prompt: Text("service_name"))
                } else {
                    TextField("路径", text: $draft.transportPath, prompt: Text("如 /ws"))
                    TextField("Host", text: $draft.transportHost, prompt: Text("可选，逗号分隔"))
                }
            }
        } header: {
            Label("传输", systemImage: "arrow.left.arrow.right")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Spacing.sm) {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "保存" : "添加") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.md)
    }

    private func save() {
        do {
            let node = try draft.build()
            onSave(node)
            dismiss()
        } catch let error as NodeDraftError {
            validationError = error.message
        } catch {
            validationError = error.localizedDescription
        }
    }
}

// =============================================================================
// MARK: - NodeDraft
// =============================================================================

/// A form-friendly, mutable projection of a `ProxyNode`: every field is a value
/// the SwiftUI controls bind to directly (text as `String`, even ports). It is
/// initialized from an existing node (edit) or sensible defaults (create), and
/// `build()` validates + assembles the final immutable `ProxyNode`.
struct NodeDraft {
    /// Preserved across an edit so the rebuilt node replaces the original in
    /// place; a fresh id for a newly created node.
    var id: UUID
    var name: String
    var protocolType: NodeProtocol
    var server: String
    var port: String

    // Credentials
    var method: String
    var password: String
    var uuid: String
    var alterId: String
    var flow: String
    var plugin: String
    var pluginOpts: String

    // TLS
    var tlsEnabled: Bool
    var sni: String
    var allowInsecure: Bool
    var alpn: String
    var utlsFingerprint: UTLSFingerprint?
    var realityPublicKey: String
    var realityShortID: String

    // Transport
    var transportType: TransportType
    var transportPath: String
    var transportHost: String
    var transportServiceName: String

    /// Common Shadowsocks ciphers offered in the method picker.
    static let shadowsocksMethods: [String] = [
        "aes-128-gcm",
        "aes-256-gcm",
        "chacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm",
        "2022-blake3-aes-256-gcm",
        "none",
    ]

    static func transportTitle(_ type: TransportType) -> String {
        switch type {
        case .tcp: return "TCP（默认）"
        case .ws: return "WebSocket"
        case .grpc: return "gRPC"
        case .http: return "HTTP/2"
        case .httpUpgrade: return "HTTPUpgrade"
        }
    }

    init(node: ProxyNode?) {
        if let node {
            id = node.id
            name = node.name
            protocolType = NodeEditorView.supports(node.protocolType) ? node.protocolType : .shadowsocks
            server = node.server
            port = String(node.port)
            method = node.method ?? NodeDraft.shadowsocksMethods[1]  // aes-256-gcm
            password = node.password ?? ""
            uuid = node.uuid ?? ""
            alterId = node.alterId.map(String.init) ?? "0"
            flow = node.flow ?? ""
            plugin = node.plugin ?? ""
            pluginOpts = node.pluginOpts ?? ""
            tlsEnabled = node.tls.enabled || node.tlsEnabled
            sni = node.tls.serverName ?? node.sni ?? ""
            allowInsecure = node.tls.insecure || node.allowInsecure
            alpn = node.tls.alpn.joined(separator: ", ")
            utlsFingerprint = node.tls.utlsFingerprint
            realityPublicKey = node.tls.reality?.publicKey ?? ""
            realityShortID = node.tls.reality?.shortID ?? ""
            transportType = node.transport.type
            transportPath = node.transport.path ?? ""
            transportHost = node.transport.host.joined(separator: ", ")
            transportServiceName = node.transport.serviceName ?? ""
        } else {
            id = UUID()
            name = ""
            protocolType = .shadowsocks
            server = ""
            port = ""
            method = NodeDraft.shadowsocksMethods[1]  // aes-256-gcm
            password = ""
            uuid = ""
            alterId = "0"
            flow = ""
            plugin = ""
            pluginOpts = ""
            tlsEnabled = false
            sni = ""
            allowInsecure = false
            alpn = ""
            utlsFingerprint = nil
            realityPublicKey = ""
            realityShortID = ""
            transportType = .tcp
            transportPath = ""
            transportHost = ""
            transportServiceName = ""
        }
    }

    /// Whether TLS is actually in effect for the current protocol — either
    /// mandated by the protocol or opted into. Drives the visibility of the
    /// SNI/insecure/ALPN/fingerprint/Reality fields.
    var tlsActive: Bool {
        protocolType.mandatesTLS || (protocolType.supportsTLS && tlsEnabled)
    }

    /// Validates and assembles the final `ProxyNode`, throwing a localized
    /// `NodeDraftError` on the first problem found.
    func build() throws -> ProxyNode {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw NodeDraftError(message: "请填写节点名称。") }

        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty else { throw NodeDraftError(message: "请填写服务器地址。") }

        let portString = port.trimmingCharacters(in: .whitespaces)
        guard let portValue = Int(portString), (1...65535).contains(portValue) else {
            throw NodeDraftError(message: "端口必须是 1–65535 之间的数字。")
        }

        // Protocol-specific required fields.
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUUID = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        switch protocolType {
        case .shadowsocks:
            guard !trimmedPassword.isEmpty else { throw NodeDraftError(message: "Shadowsocks 需要填写密码。") }
        case .vmess, .vless:
            guard !trimmedUUID.isEmpty else { throw NodeDraftError(message: "\(ProtocolPresentation.title(protocolType)) 需要填写 UUID。") }
        case .trojan, .hysteria2:
            guard !trimmedPassword.isEmpty else { throw NodeDraftError(message: "\(ProtocolPresentation.title(protocolType)) 需要填写密码。") }
        case .tuic:
            guard !trimmedUUID.isEmpty else { throw NodeDraftError(message: "TUIC 需要填写 UUID。") }
        case .wireguard, .ssh:
            throw NodeDraftError(message: "该协议不支持手动编辑。")
        }

        let tls = buildTLS()
        let transport = buildTransport()

        return ProxyNode(
            id: id,
            name: trimmedName,
            protocolType: protocolType,
            server: trimmedServer,
            port: portValue,
            password: usesPassword ? trimmedPassword.nilIfEmpty : nil,
            uuid: usesUUID ? trimmedUUID.nilIfEmpty : nil,
            method: protocolType == .shadowsocks ? method : nil,
            alterId: protocolType == .vmess ? Int(alterId.trimmingCharacters(in: .whitespaces)) : nil,
            flow: protocolType == .vless ? flow.trimmingCharacters(in: .whitespaces).nilIfEmpty : nil,
            tlsEnabled: tls.enabled,
            sni: tls.serverName,
            allowInsecure: tls.insecure,
            tls: tls,
            transport: transport,
            plugin: protocolType == .shadowsocks ? plugin.trimmingCharacters(in: .whitespaces).nilIfEmpty : nil,
            pluginOpts: protocolType == .shadowsocks ? pluginOpts.trimmingCharacters(in: .whitespaces).nilIfEmpty : nil,
            wireGuard: nil,
            ssh: nil
        )
    }

    /// Protocols whose credentials carry a password field.
    private var usesPassword: Bool {
        switch protocolType {
        case .shadowsocks, .trojan, .hysteria2, .tuic: return true
        case .vmess, .vless, .wireguard, .ssh: return false
        }
    }

    /// Protocols whose credentials carry a UUID field.
    private var usesUUID: Bool {
        switch protocolType {
        case .vmess, .vless, .tuic: return true
        case .shadowsocks, .trojan, .hysteria2, .wireguard, .ssh: return false
        }
    }

    private func buildTLS() -> TLSOptions {
        guard tlsActive else { return .disabled }
        let alpnList = alpn
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let reality: RealityOptions?
        let trimmedKey = realityPublicKey.trimmingCharacters(in: .whitespaces)
        if trimmedKey.isEmpty {
            reality = nil
        } else {
            reality = RealityOptions(
                enabled: true,
                publicKey: trimmedKey,
                shortID: realityShortID.trimmingCharacters(in: .whitespaces)
            )
        }
        return TLSOptions(
            enabled: true,
            serverName: sni.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            insecure: allowInsecure,
            alpn: alpnList,
            utlsFingerprint: utlsFingerprint,
            reality: reality
        )
    }

    private func buildTransport() -> TransportOptions {
        guard protocolType.supportsTransport, transportType != .tcp else { return .tcp }
        let hosts = transportHost
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return TransportOptions(
            type: transportType,
            path: transportPath.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            headers: [:],
            host: hosts,
            serviceName: transportServiceName.trimmingCharacters(in: .whitespaces).nilIfEmpty
        )
    }
}

/// A localized validation failure surfaced inline beneath the form.
struct NodeDraftError: Error {
    let message: String
}

// =============================================================================
// MARK: - Protocol capability helpers
// =============================================================================

private extension NodeProtocol {
    /// Whether a TLS block is meaningful for this protocol (optional or
    /// mandatory). Shadowsocks rides its own cipher and emits no TLS here.
    var supportsTLS: Bool {
        switch self {
        case .vmess, .vless, .trojan, .hysteria2, .tuic: return true
        case .shadowsocks, .wireguard, .ssh: return false
        }
    }

    /// Whether this protocol always runs over TLS (so the toggle is implicit).
    var mandatesTLS: Bool {
        switch self {
        case .trojan, .hysteria2, .tuic: return true
        case .shadowsocks, .vmess, .vless, .wireguard, .ssh: return false
        }
    }

    /// Whether a v2ray transport (ws/grpc/http/httpupgrade) applies. QUIC
    /// protocols (hysteria2/tuic) and shadowsocks do not carry one.
    var supportsTransport: Bool {
        switch self {
        case .vmess, .vless, .trojan: return true
        case .shadowsocks, .hysteria2, .tuic, .wireguard, .ssh: return false
        }
    }
}

private extension String {
    /// `nil` when the string is empty, else the string — for folding empty form
    /// fields into absent optionals.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
