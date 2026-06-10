import Foundation

/// Proxy protocols supported by linko.
///
/// Raw values match the `type` field used in Clash YAML subscriptions.
public enum NodeProtocol: String, Codable, CaseIterable, Hashable, Sendable {
    case shadowsocks = "ss"
    case vmess
    case trojan
    case vless
    case hysteria2
    case tuic
    /// WireGuard. In sing-box 1.11+ this is no longer an outbound; it is a
    /// top-level `endpoint` (see `isEndpoint`). It is still referenceable as an
    /// outbound *tag* by rules and policy groups.
    case wireguard
    /// SSH tunnel. Remains a regular outbound in sing-box 1.13.
    case ssh

    /// The `type` string expected by the sing-box 1.x config schema, identical
    /// for both `outbounds[]` entries and `endpoints[]` entries.
    public var singBoxOutboundType: String {
        switch self {
        case .shadowsocks:
            return "shadowsocks"
        case .vmess, .trojan, .vless, .hysteria2, .tuic, .wireguard, .ssh:
            return rawValue
        }
    }

    /// Whether sing-box 1.11+ models this protocol as a top-level `endpoint`
    /// (the `endpoints[]` array) rather than an `outbound`. Only WireGuard
    /// migrated; the config builder places these in `endpoints[]` while keeping
    /// their `tag` referenceable by rules/groups exactly like an outbound.
    public var isEndpoint: Bool {
        self == .wireguard
    }
}
