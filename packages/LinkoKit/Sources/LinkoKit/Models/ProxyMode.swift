import Foundation

/// How linko intercepts traffic.
///
/// - `systemProxy`: a local `mixed` inbound plus macOS system-proxy settings
///   (only covers apps that honor the system proxy). The M1 default; runs the
///   core as a subprocess.
/// - `tun`: a `tun` inbound that captures all traffic via a virtual interface,
///   run inside a NetworkExtension system extension (M2). Covers apps that
///   ignore the system proxy.
public enum ProxyMode: String, Codable, CaseIterable, Hashable, Sendable {
    case systemProxy = "system_proxy"
    case tun

    /// Chinese label for the UI.
    public var displayName: String {
        switch self {
        case .systemProxy: return "系统代理"
        case .tun: return "TUN 全局"
        }
    }
}
