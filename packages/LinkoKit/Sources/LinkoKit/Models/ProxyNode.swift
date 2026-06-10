import Foundation

/// A single proxy server entry, normalized from a subscription source.
///
/// Only the fields required by the MVP protocol set are modeled. Fields that
/// do not apply to a given protocol are `nil`.
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

    public var tlsEnabled: Bool
    /// TLS server name (Clash `sni` / `servername`).
    public var sni: String?
    /// Clash `skip-cert-verify`.
    public var allowInsecure: Bool

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
        allowInsecure: Bool = false
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
    }
}
