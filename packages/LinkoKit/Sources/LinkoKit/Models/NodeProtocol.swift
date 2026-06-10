import Foundation

/// Proxy protocols supported by linko's MVP.
///
/// Raw values match the `type` field used in Clash YAML subscriptions.
public enum NodeProtocol: String, Codable, CaseIterable, Hashable, Sendable {
    case shadowsocks = "ss"
    case vmess
    case trojan
    case vless
    case hysteria2
    case tuic

    /// The outbound `type` string expected by the sing-box 1.x config schema.
    public var singBoxOutboundType: String {
        switch self {
        case .shadowsocks:
            return "shadowsocks"
        case .vmess, .trojan, .vless, .hysteria2, .tuic:
            return rawValue
        }
    }
}
