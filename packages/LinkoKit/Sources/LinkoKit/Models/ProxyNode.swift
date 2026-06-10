import Foundation

/// uTLS ClientHello fingerprint presets, mapped to sing-box `tls.utls.fingerprint`.
///
/// Raw values are the exact strings sing-box accepts; see
/// https://sing-box.sagernet.org/configuration/shared/tls/
public enum UTLSFingerprint: String, Codable, CaseIterable, Hashable, Sendable {
    case chrome
    case firefox
    case edge
    case safari
    case ios
    case android
    case random
    case randomized
}

/// Application-layer transport carrying the proxy protocol, mapped to the
/// sing-box `transport` block on vmess/vless/trojan outbounds.
///
/// See https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
public enum TransportType: String, Codable, CaseIterable, Hashable, Sendable {
    /// Plain TCP — no `transport` block is emitted.
    case tcp
    /// WebSocket — `{type:"ws", path, headers}`.
    case ws
    /// gRPC — `{type:"grpc", service_name}`.
    case grpc
    /// HTTP/2 — `{type:"http", host, path}`.
    case http
    /// HTTP Upgrade — `{type:"httpupgrade", host, path, headers}`.
    case httpUpgrade = "httpupgrade"
}

/// TLS settings shared by every protocol that runs over TLS, mapped to the
/// sing-box outbound `tls` object.
///
/// See https://sing-box.sagernet.org/configuration/shared/tls/
public struct TLSOptions: Codable, Hashable, Sendable {
    /// `tls.enabled`. When `false`, no `tls` object is emitted (unless the
    /// protocol mandates TLS, e.g. trojan/hysteria2/tuic).
    public var enabled: Bool
    /// `tls.server_name` (Clash `sni` / `servername`). `nil` ⇒ use `server`.
    public var serverName: String?
    /// `tls.insecure` (Clash `skip-cert-verify`).
    public var insecure: Bool
    /// `tls.alpn`. Empty ⇒ field omitted.
    public var alpn: [String]
    /// `tls.utls.fingerprint` (Clash `client-fingerprint`). `nil` ⇒ utls omitted.
    public var utlsFingerprint: UTLSFingerprint?
    /// `tls.reality`. `nil` ⇒ reality omitted.
    public var reality: RealityOptions?

    public init(
        enabled: Bool = false,
        serverName: String? = nil,
        insecure: Bool = false,
        alpn: [String] = [],
        utlsFingerprint: UTLSFingerprint? = nil,
        reality: RealityOptions? = nil
    ) {
        self.enabled = enabled
        self.serverName = serverName
        self.insecure = insecure
        self.alpn = alpn
        self.utlsFingerprint = utlsFingerprint
        self.reality = reality
    }

    public static let disabled = TLSOptions()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.serverName = try c.decodeIfPresent(String.self, forKey: .serverName)
        self.insecure = try c.decodeIfPresent(Bool.self, forKey: .insecure) ?? false
        self.alpn = try c.decodeIfPresent([String].self, forKey: .alpn) ?? []
        self.utlsFingerprint = try c.decodeIfPresent(UTLSFingerprint.self, forKey: .utlsFingerprint)
        self.reality = try c.decodeIfPresent(RealityOptions.self, forKey: .reality)
    }
}

/// REALITY anti-censorship TLS settings, mapped to `tls.reality`.
///
/// See https://sing-box.sagernet.org/configuration/shared/tls/
public struct RealityOptions: Codable, Hashable, Sendable {
    /// `tls.reality.enabled`.
    public var enabled: Bool
    /// `tls.reality.public_key` (Clash `reality-opts.public-key`).
    public var publicKey: String
    /// `tls.reality.short_id` (Clash `reality-opts.short-id`).
    public var shortID: String

    public init(enabled: Bool = true, publicKey: String, shortID: String = "") {
        self.enabled = enabled
        self.publicKey = publicKey
        self.shortID = shortID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        self.shortID = try c.decodeIfPresent(String.self, forKey: .shortID) ?? ""
    }
}

/// Application-layer transport details, mapped to the sing-box `transport`
/// block. Only the fields relevant to `type` are emitted by the builder.
///
/// See https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
public struct TransportOptions: Codable, Hashable, Sendable {
    public var type: TransportType
    /// `transport.path` (ws/http/httpupgrade). Clash `ws-opts.path` / `h2-opts.path`.
    public var path: String?
    /// `transport.headers` (ws/http/httpupgrade). Clash `ws-opts.headers`.
    /// The `Host` header is folded into `host` when present.
    public var headers: [String: String]
    /// `transport.host` — `[String]` for http, single string for ws/httpupgrade
    /// Host header. Clash `ws-opts.headers.Host` / `h2-opts.host`.
    public var host: [String]
    /// `transport.service_name` (grpc). Clash `grpc-opts.grpc-service-name`.
    public var serviceName: String?

    public init(
        type: TransportType = .tcp,
        path: String? = nil,
        headers: [String: String] = [:],
        host: [String] = [],
        serviceName: String? = nil
    ) {
        self.type = type
        self.path = path
        self.headers = headers
        self.host = host
        self.serviceName = serviceName
    }

    public static let tcp = TransportOptions(type: .tcp)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decodeIfPresent(TransportType.self, forKey: .type) ?? .tcp
        self.path = try c.decodeIfPresent(String.self, forKey: .path)
        self.headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.host = try c.decodeIfPresent([String].self, forKey: .host) ?? []
        self.serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName)
    }
}

/// A single proxy server entry, normalized from a subscription source.
///
/// Fields that do not apply to a given protocol are `nil`/default. New
/// transport/TLS/Reality fields are optional and tolerantly decoded so that
/// subscriptions persisted before M3 still load.
public struct ProxyNode: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID

    /// Display name; also used as the sing-box outbound tag (deduplicated by the config builder if needed).
    public var name: String
    public var protocolType: NodeProtocol
    public var server: String
    public var port: Int

    // MARK: Credentials

    /// shadowsocks / trojan / hysteria2 / tuic password.
    public var password: String?
    /// vmess / vless / tuic UUID.
    public var uuid: String?
    /// shadowsocks cipher method (Clash `cipher`).
    public var method: String?
    /// vmess alter id (Clash `alterId`), defaults to 0 when absent.
    public var alterId: Int?
    /// vless flow, e.g. "xtls-rprx-vision".
    public var flow: String?

    // MARK: TLS

    /// Whether TLS is enabled. Protocols that mandate TLS (trojan, hysteria2,
    /// tuic) emit TLS regardless of this flag.
    public var tlsEnabled: Bool
    /// TLS server name (Clash `sni` / `servername`). Mirrors `tls.serverName`.
    public var sni: String?
    /// Clash `skip-cert-verify`. Mirrors `tls.insecure`.
    public var allowInsecure: Bool
    /// Full TLS settings (alpn, utls fingerprint, reality). The legacy
    /// `tlsEnabled`/`sni`/`allowInsecure` mirror this struct's primary fields
    /// for backward compatibility and simple editors; the builder reads `tls`.
    public var tls: TLSOptions

    // MARK: Transport

    /// Application-layer transport (ws/grpc/http/httpupgrade). Defaults to TCP.
    public var transport: TransportOptions

    // MARK: shadowsocks plugin

    /// `plugin` (shadowsocks SIP003): `obfs-local` or `v2ray-plugin`. Clash `plugin`.
    public var plugin: String?
    /// `plugin_opts` string. Built from Clash `plugin-opts` mapping.
    public var pluginOpts: String?

    public init(
        id: UUID = UUID(),
        name: String,
        protocolType: NodeProtocol,
        server: String,
        port: Int,
        password: String? = nil,
        uuid: String? = nil,
        method: String? = nil,
        alterId: Int? = nil,
        flow: String? = nil,
        tlsEnabled: Bool = false,
        sni: String? = nil,
        allowInsecure: Bool = false,
        tls: TLSOptions? = nil,
        transport: TransportOptions = .tcp,
        plugin: String? = nil,
        pluginOpts: String? = nil
    ) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.server = server
        self.port = port
        self.password = password
        self.uuid = uuid
        self.method = method
        self.alterId = alterId
        self.flow = flow
        self.tlsEnabled = tlsEnabled
        self.sni = sni
        self.allowInsecure = allowInsecure
        // Keep the convenience struct consistent with the mirrored flags unless
        // an explicit `tls` was supplied.
        self.tls = tls ?? TLSOptions(enabled: tlsEnabled, serverName: sni, insecure: allowInsecure)
        self.transport = transport
        self.plugin = plugin
        self.pluginOpts = pluginOpts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.protocolType = try c.decode(NodeProtocol.self, forKey: .protocolType)
        self.server = try c.decode(String.self, forKey: .server)
        self.port = try c.decode(Int.self, forKey: .port)
        self.password = try c.decodeIfPresent(String.self, forKey: .password)
        self.uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        self.method = try c.decodeIfPresent(String.self, forKey: .method)
        self.alterId = try c.decodeIfPresent(Int.self, forKey: .alterId)
        self.flow = try c.decodeIfPresent(String.self, forKey: .flow)
        let tlsEnabled = try c.decodeIfPresent(Bool.self, forKey: .tlsEnabled) ?? false
        let sni = try c.decodeIfPresent(String.self, forKey: .sni)
        let allowInsecure = try c.decodeIfPresent(Bool.self, forKey: .allowInsecure) ?? false
        self.tlsEnabled = tlsEnabled
        self.sni = sni
        self.allowInsecure = allowInsecure
        self.tls = try c.decodeIfPresent(TLSOptions.self, forKey: .tls)
            ?? TLSOptions(enabled: tlsEnabled, serverName: sni, insecure: allowInsecure)
        self.transport = try c.decodeIfPresent(TransportOptions.self, forKey: .transport) ?? .tcp
        self.plugin = try c.decodeIfPresent(String.self, forKey: .plugin)
        self.pluginOpts = try c.decodeIfPresent(String.self, forKey: .pluginOpts)
    }
}
