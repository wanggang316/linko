import LinkoKit
import SwiftUI

/// Native grouped editor for the sing-box **DNS** layer: upstream servers
/// (UDP / TLS / HTTPS / QUIC / local), a default resolution strategy, a small
/// set of routing rules (e.g. send `geosite-cn` to a domestic resolver), and a
/// fake-ip toggle that stays disabled in system-proxy mode (it pairs with TUN,
/// shipping in M2).
///
/// DNS is off by default — when the master switch is off the builder emits no
/// `dns` block and the core's defaults apply (pre-M3 behavior). Edits persist by
/// writing the mutated `RoutingConfig` back through `AppState.updatePreferences`.
struct DNSSettingsView: View {
    @EnvironmentObject private var appState: AppState

    private var dns: DNSConfig { appState.preferences.routing.dns }

    var body: some View {
        Form {
            masterSection
            // Static host mappings work standalone (no upstream servers needed),
            // so the editor is always available — even with DNS turned off.
            hostsSection
            if dns.isEnabled {
                serversSection
                strategySection
                rulesSection
                fakeIPSection
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 600)
    }

    // MARK: - Master switch

    private var masterSection: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("启用 DNS 配置")
                        Text("关闭时由 sing-box 使用系统默认解析。")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "network")
                        .foregroundStyle(Theme.Color.accent)
                }
            }
            if dns.isEnabled {
                Button {
                    apply { $0 = .recommended() }
                } label: {
                    Label("载入推荐配置", systemImage: "wand.and.stars")
                }
                .help("国内域名走直连解析、其余走加密上游，并附带一条 geosite-cn 规则")
            }
        } header: {
            Text("DNS")
        } footer: {
            Text("分流解析可避免 DNS 污染：国内站点用国内解析，其余走加密上游。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { dns.isEnabled },
            set: { isOn in
                apply { config in
                    if isOn && config.servers.isEmpty {
                        config = .recommended()
                    } else {
                        config.isEnabled = isOn
                    }
                }
            }
        )
    }

    // MARK: - Static hosts

    private var hostsSection: some View {
        Section {
            if dns.hosts.isEmpty {
                Text("尚无本地映射。例如：router.lan → 192.168.1.1。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
            ForEach(dns.hosts) { host in
                HostEntryRow(
                    host: host,
                    onChange: { updated in updateHost(updated) },
                    onDelete: { deleteHost(host) }
                )
            }
            Button {
                addHost()
            } label: {
                Label("添加映射", systemImage: "plus")
            }
        } header: {
            Text("本地 Hosts 映射")
        } footer: {
            Text("把域名直接指向固定 IP，优先级高于所有上游解析。地址支持 IPv4 / IPv6，多个用逗号分隔。无需开启上方 DNS 配置即可生效。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - Servers

    private var serversSection: some View {
        Section {
            if dns.servers.isEmpty {
                Text("尚无 DNS 服务器，点击下方「添加服务器」。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
            ForEach(dns.servers) { server in
                DNSServerRow(
                    server: server,
                    onChange: { updated in updateServer(updated) },
                    onDelete: { deleteServer(server) }
                )
            }
            Button {
                addServer()
            } label: {
                Label("添加服务器", systemImage: "plus")
            }
        } header: {
            Text("服务器")
        } footer: {
            Text("标签（tag）供下方规则与「最终解析」引用。直连解析建议将出站设为 direct。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - Strategy

    private var strategySection: some View {
        Section {
            Picker(selection: strategyBinding) {
                Text("默认（不限定）").tag(DNSStrategy?.none)
                ForEach(DNSStrategy.allCases, id: \.self) { strategy in
                    Text(strategy.displayName).tag(DNSStrategy?.some(strategy))
                }
            } label: {
                Label("解析策略", systemImage: "arrow.triangle.branch")
            }
            .pickerStyle(.menu)

            Picker(selection: finalServerBinding) {
                Text("默认（首个服务器）").tag(String?.none)
                ForEach(dns.servers) { server in
                    Text(server.tag).tag(String?.some(server.tag))
                }
            } label: {
                Label("最终解析", systemImage: "flag.checkered")
            }
            .pickerStyle(.menu)

            Toggle(isOn: disableCacheBinding) {
                Label("禁用 DNS 缓存", systemImage: "xmark.bin")
            }
        } header: {
            Text("策略")
        } footer: {
            Text("「最终解析」对应 dns.final——未命中任何规则时使用的服务器。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    private var strategyBinding: Binding<DNSStrategy?> {
        Binding(get: { dns.strategy }, set: { value in apply { $0.strategy = value } })
    }

    private var finalServerBinding: Binding<String?> {
        Binding(get: { dns.finalServerTag }, set: { value in apply { $0.finalServerTag = value } })
    }

    private var disableCacheBinding: Binding<Bool> {
        Binding(get: { dns.disableCache }, set: { value in apply { $0.disableCache = value } })
    }

    // MARK: - Rules

    private var rulesSection: some View {
        Section {
            if dns.rules.isEmpty {
                Text("尚无解析规则。例如：geosite-cn → 国内服务器。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
            ForEach(dns.rules) { rule in
                DNSRuleRow(
                    rule: rule,
                    serverTags: dns.servers.map(\.tag),
                    onChange: { updated in updateRule(updated) },
                    onDelete: { deleteRule(rule) }
                )
            }
            Button {
                addRule()
            } label: {
                Label("添加规则", systemImage: "plus")
            }
            .disabled(dns.servers.isEmpty)
        } header: {
            Text("解析规则")
        } footer: {
            Text("规则按顺序匹配，命中即用对应服务器解析。geosite/rule-set 取值为规则集标签。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - FakeIP

    private var fakeIPSection: some View {
        Section {
            Toggle(isOn: .constant(false)) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Fake-IP")
                        Text("需配合 TUN 模式使用，将在 M2 提供。")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "theatermasks")
                        .foregroundStyle(Theme.Color.tertiaryLabel)
                }
            }
            .disabled(true)
        } header: {
            Text("Fake-IP")
        } footer: {
            Text("系统代理模式下 Fake-IP 无效，故默认关闭并禁用。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - Server mutations

    private func addServer() {
        apply { config in
            var index = config.servers.count + 1
            var tag = "dns-\(index)"
            let taken = Set(config.servers.map(\.tag))
            while taken.contains(tag) {
                index += 1
                tag = "dns-\(index)"
            }
            config.servers.append(DNSServer(tag: tag, address: "https://1.1.1.1/dns-query"))
        }
    }

    private func updateServer(_ server: DNSServer) {
        apply { config in
            if let index = config.servers.firstIndex(where: { $0.id == server.id }) {
                config.servers[index] = server
            }
        }
    }

    private func deleteServer(_ server: DNSServer) {
        apply { config in
            config.servers.removeAll { $0.id == server.id }
        }
    }

    // MARK: - Rule mutations

    private func addRule() {
        apply { config in
            let server = config.servers.first?.tag ?? ""
            config.rules.append(DNSRule(matcher: .ruleSet, value: "geosite-cn", server: server))
        }
    }

    private func updateRule(_ rule: DNSRule) {
        apply { config in
            if let index = config.rules.firstIndex(where: { $0.id == rule.id }) {
                config.rules[index] = rule
            }
        }
    }

    private func deleteRule(_ rule: DNSRule) {
        apply { config in
            config.rules.removeAll { $0.id == rule.id }
        }
    }

    // MARK: - Host mutations

    private func addHost() {
        apply { config in
            config.hosts.append(HostEntry(domain: "", addresses: ""))
        }
    }

    private func updateHost(_ host: HostEntry) {
        apply { config in
            if let index = config.hosts.firstIndex(where: { $0.id == host.id }) {
                config.hosts[index] = host
            }
        }
    }

    private func deleteHost(_ host: HostEntry) {
        apply { config in
            config.hosts.removeAll { $0.id == host.id }
        }
    }

    // MARK: - Commit

    /// Mutates the DNS config in place and persists the whole preferences value.
    private func apply(_ mutate: (inout DNSConfig) -> Void) {
        var preferences = appState.preferences
        mutate(&preferences.routing.dns)
        Task { await appState.updatePreferences(preferences) }
    }
}

// =============================================================================
// MARK: - Server row
// =============================================================================

/// One editable DNS server row: tag, transport (UDP/TLS/HTTPS/QUIC/local),
/// host/address, and the outbound detour used to reach it.
private struct DNSServerRow: View {
    let server: DNSServer
    let onChange: (DNSServer) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                TextField("标签", text: tagBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.monoSmall)
                    .frame(width: 140)
                Picker("", selection: transportBinding) {
                    ForEach(DNSTransport.allCases, id: \.self) { transport in
                        Text(transport.displayName).tag(transport)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Color.error)
            }

            if currentTransport.needsHost {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(currentTransport.scheme)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.tertiaryLabel)
                    TextField(currentTransport.hostPrompt, text: hostBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.monoSmall)
                }
            }

            HStack(spacing: Theme.Spacing.xs) {
                Text("出站")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                Picker("", selection: detourBinding) {
                    Text("自动").tag("")
                    Text("direct").tag("direct")
                    Text("proxy").tag("proxy")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    // MARK: Bindings

    private var tagBinding: Binding<String> {
        Binding(get: { server.tag }, set: { var s = server; s.tag = $0; onChange(s) })
    }

    private var currentTransport: DNSTransport {
        DNSTransport(address: server.address)
    }

    private var transportBinding: Binding<DNSTransport> {
        Binding(
            get: { currentTransport },
            set: { newTransport in
                var s = server
                s.address = newTransport.compose(host: currentTransport.host(from: server.address))
                onChange(s)
            }
        )
    }

    private var hostBinding: Binding<String> {
        Binding(
            get: { currentTransport.host(from: server.address) },
            set: { newHost in
                var s = server
                s.address = currentTransport.compose(host: newHost)
                onChange(s)
            }
        )
    }

    private var detourBinding: Binding<String> {
        Binding(
            get: { server.detour ?? "" },
            set: { var s = server; s.detour = $0.isEmpty ? nil : $0; onChange(s) }
        )
    }
}

// =============================================================================
// MARK: - Host row
// =============================================================================

/// One editable static-host row: an exact domain, its comma-separated IP
/// literals, an enable toggle, and a delete button.
private struct HostEntryRow: View {
    let host: HostEntry
    let onChange: (HostEntry) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                TextField("域名（router.lan）", text: domainBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.monoSmall)
                    .frame(width: 180)
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(host.isEnabled ? "已启用" : "已停用")
                Spacer()
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
                TextField("IP 地址，逗号分隔（127.0.0.1, ::1）", text: addressesBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.monoSmall)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .opacity(host.isEnabled ? 1 : 0.5)
    }

    private var domainBinding: Binding<String> {
        Binding(get: { host.domain }, set: { var h = host; h.domain = $0; onChange(h) })
    }

    private var addressesBinding: Binding<String> {
        Binding(get: { host.addresses }, set: { var h = host; h.addresses = $0; onChange(h) })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { host.isEnabled }, set: { var h = host; h.isEnabled = $0; onChange(h) })
    }
}

// =============================================================================
// MARK: - Rule row
// =============================================================================

/// One editable DNS rule row: matcher, value, and the target server tag.
private struct DNSRuleRow: View {
    let rule: DNSRule
    let serverTags: [String]
    let onChange: (DNSRule) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Picker("", selection: matcherBinding) {
                ForEach(DNSRuleMatcher.allCases, id: \.self) { matcher in
                    Text(matcher.displayName).tag(matcher)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            TextField(rule.matcher.valuePrompt, text: valueBinding)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.monoSmall)

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(Theme.Color.tertiaryLabel)

            Picker("", selection: serverBinding) {
                if serverTags.isEmpty {
                    Text("无服务器").tag("")
                }
                ForEach(serverTags, id: \.self) { tag in
                    Text(tag).tag(tag)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Color.error)
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private var matcherBinding: Binding<DNSRuleMatcher> {
        Binding(get: { rule.matcher }, set: { var r = rule; r.matcher = $0; onChange(r) })
    }

    private var valueBinding: Binding<String> {
        Binding(get: { rule.value }, set: { var r = rule; r.value = $0; onChange(r) })
    }

    private var serverBinding: Binding<String> {
        Binding(get: { rule.server }, set: { var r = rule; r.server = $0; onChange(r) })
    }
}

// =============================================================================
// MARK: - Transport modeling
// =============================================================================

/// The DNS transport schemes linko surfaces in the picker. Each composes a full
/// `dns.servers[].address` string and parses one back into a host fragment so
/// the row can edit type + host as two controls while the model stays a single
/// address URL.
private enum DNSTransport: String, CaseIterable, Hashable {
    case udp
    case tls
    case https
    case quic
    case h3
    case local

    init(address: String) {
        let lower = address.lowercased()
        if lower == "local" || lower.hasPrefix("local") { self = .local }
        else if lower.hasPrefix("tls://") { self = .tls }
        else if lower.hasPrefix("https://") { self = .https }
        else if lower.hasPrefix("quic://") { self = .quic }
        else if lower.hasPrefix("h3://") { self = .h3 }
        else { self = .udp }
    }

    var displayName: String {
        switch self {
        case .udp: return "UDP"
        case .tls: return "DoT (TLS)"
        case .https: return "DoH (HTTPS)"
        case .quic: return "DoQ (QUIC)"
        case .h3: return "DoH3"
        case .local: return "本地"
        }
    }

    var needsHost: Bool { self != .local }

    var scheme: String {
        switch self {
        case .udp: return "udp://"
        case .tls: return "tls://"
        case .https: return "https://"
        case .quic: return "quic://"
        case .h3: return "h3://"
        case .local: return ""
        }
    }

    var hostPrompt: String {
        switch self {
        case .https, .h3: return "1.1.1.1/dns-query"
        default: return "1.1.1.1"
        }
    }

    /// Strips the scheme from a stored address to get the editable host part.
    func host(from address: String) -> String {
        if self == .local { return "" }
        let prefix = scheme
        if address.lowercased().hasPrefix(prefix) {
            return String(address.dropFirst(prefix.count))
        }
        // Address used a different scheme; strip any leading scheme.
        if let range = address.range(of: "://") {
            return String(address[range.upperBound...])
        }
        return address
    }

    /// Builds the full `address` string for this transport from a host fragment.
    func compose(host: String) -> String {
        if self == .local { return "local" }
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        var body = trimmed
        // DoH/DoH3 conventionally include the /dns-query path.
        if (self == .https || self == .h3), !body.isEmpty, !body.contains("/") {
            body += "/dns-query"
        }
        return scheme + body
    }
}

// =============================================================================
// MARK: - Display helpers
// =============================================================================

private extension DNSStrategy {
    var displayName: String {
        switch self {
        case .preferIPv4: return "优先 IPv4"
        case .preferIPv6: return "优先 IPv6"
        case .ipv4Only: return "仅 IPv4"
        case .ipv6Only: return "仅 IPv6"
        }
    }
}

private extension DNSRuleMatcher {
    var displayName: String {
        switch self {
        case .domain: return "域名"
        case .domainSuffix: return "域名后缀"
        case .domainKeyword: return "域名关键字"
        case .domainRegex: return "域名正则"
        case .geosite: return "GeoSite"
        case .ruleSet: return "规则集"
        case .clashMode: return "Clash 模式"
        }
    }

    var valuePrompt: String {
        switch self {
        case .domain: return "example.com"
        case .domainSuffix: return "example.com"
        case .domainKeyword: return "keyword"
        case .domainRegex: return "^.*\\.example\\.com$"
        case .geosite: return "geosite-cn"
        case .ruleSet: return "geosite-cn"
        case .clashMode: return "global / rule / direct"
        }
    }
}
