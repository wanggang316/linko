import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - RuleType presentation
// =============================================================================

/// View-layer presentation metadata for `RuleType`: a Chinese display name, an
/// SF Symbol, a placeholder for the value field, and grouping for the picker.
/// Kept in the UI layer so the model stays free of presentation concerns.
extension RuleType {
    /// Short Chinese label shown in the rule row's type chip and the picker.
    var displayName: String {
        switch self {
        case .domain: return "域名"
        case .domainSuffix: return "域名后缀"
        case .domainKeyword: return "域名关键词"
        case .domainRegex: return "域名正则"
        case .ipCIDR: return "IP 段"
        case .ipCIDR6: return "IPv6 段"
        case .srcIPCIDR: return "来源 IP 段"
        case .geoip: return "GeoIP"
        case .geosite: return "GeoSite"
        case .ruleSet: return "规则集"
        case .processName: return "进程名"
        case .processPath: return "进程路径"
        case .port: return "端口"
        case .destPort: return "目标端口"
        case .srcPort: return "来源端口"
        case .network: return "网络类型"
        case .protocolSniff: return "应用协议"
        case .and: return "逻辑与 (AND)"
        case .or: return "逻辑或 (OR)"
        case .not: return "逻辑非 (NOT)"
        case .final: return "兜底 (FINAL)"
        }
    }

    /// The raw Surge/Clash token (the enum's raw value), shown as a monospace
    /// badge so power users recognize the underlying rule keyword.
    var token: String { rawValue }

    /// SF Symbol that visually classifies the rule kind in a row.
    var symbolName: String {
        switch self {
        case .domain, .domainSuffix, .domainKeyword, .domainRegex:
            return "globe"
        case .ipCIDR, .ipCIDR6, .srcIPCIDR:
            return "number.circle"
        case .geoip:
            return "map"
        case .geosite:
            return "globe.asia.australia"
        case .ruleSet:
            return "list.bullet.rectangle"
        case .processName, .processPath:
            return "app.badge"
        case .port, .destPort, .srcPort:
            return "bolt.horizontal"
        case .network:
            return "network"
        case .protocolSniff:
            return "shield.lefthalf.filled"
        case .and, .or, .not:
            return "curlybraces"
        case .final:
            return "flag.checkered"
        }
    }

    /// Placeholder text for the value field in the editor, describing what the
    /// matcher expects. Empty for rule kinds that take no literal value.
    var valuePlaceholder: String {
        switch self {
        case .domain: return "example.com"
        case .domainSuffix: return "google.com"
        case .domainKeyword: return "google"
        case .domainRegex: return "^.*\\.example\\.com$"
        case .ipCIDR: return "192.168.0.0/16"
        case .ipCIDR6: return "2001:db8::/32"
        case .srcIPCIDR: return "192.168.1.0/24"
        case .geoip: return "cn"
        case .geosite: return "geolocation-!cn"
        case .ruleSet: return "选择规则集标签"
        case .processName: return "Telegram"
        case .processPath: return "/Applications/Telegram.app/..."
        case .port, .destPort, .srcPort: return "443  或  8000:9000"
        case .network: return "tcp  /  udp"
        case .protocolSniff: return "tls / http / quic"
        case .and, .or, .not: return ""
        case .final: return ""
        }
    }

    /// Whether the editor should surface the literal value field for this kind.
    /// Logical combinators and `.final` carry no literal value; rule-set kinds
    /// reference a tag through a dedicated picker rather than a free text field.
    var editsLiteralValue: Bool {
        !isLogical && !isFinal && !usesRuleSet
    }

    /// Coarse category used to group the type picker into labelled sections.
    var category: RuleTypeCategory {
        switch self {
        case .domain, .domainSuffix, .domainKeyword, .domainRegex:
            return .domain
        case .ipCIDR, .ipCIDR6, .srcIPCIDR, .geoip:
            return .ip
        case .geosite, .ruleSet:
            return .ruleSet
        case .processName, .processPath:
            return .process
        case .port, .destPort, .srcPort, .network, .protocolSniff:
            return .transport
        case .and, .or, .not:
            return .logical
        case .final:
            return .fallback
        }
    }
}

/// Labelled groupings for the rule-type picker, so a long flat list reads as a
/// curated menu instead of an alphabet soup.
enum RuleTypeCategory: String, CaseIterable, Hashable {
    case domain
    case ip
    case ruleSet
    case process
    case transport
    case logical
    case fallback

    var title: String {
        switch self {
        case .domain: return "域名"
        case .ip: return "IP / 地区"
        case .ruleSet: return "规则集"
        case .process: return "进程"
        case .transport: return "端口 / 协议"
        case .logical: return "逻辑组合"
        case .fallback: return "兜底"
        }
    }

    var types: [RuleType] {
        RuleType.allCases.filter { $0.category == self }
    }
}
