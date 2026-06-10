import Foundation
import Yams

/// Errors thrown when a subscription document is not parseable at all.
/// Per-entry problems are reported as warnings, never as throws.
public enum SubscriptionParserError: Error, Equatable, LocalizedError {
    case invalidYAML(detail: String)
    case missingProxiesSection

    public var errorDescription: String? {
        switch self {
        case let .invalidYAML(detail):
            return "The subscription is not valid Clash YAML: \(detail)"
        case .missingProxiesSection:
            return "The subscription document does not contain a \"proxies\" list."
        }
    }
}

/// Parses Clash YAML subscription documents into `ProxyNode`s.
///
/// Supported `type` values: ss, vmess, trojan, vless, hysteria2, tuic.
/// Entries with unknown types or missing required fields are skipped with a
/// warning instead of failing the whole document.
public struct SubscriptionParser: SubscriptionParsing {
    public init() {}

    public func parse(clashYAML: String) throws -> SubscriptionParseResult {
        let root: Any?
        do {
            root = try Yams.load(yaml: clashYAML)
        } catch {
            throw SubscriptionParserError.invalidYAML(detail: String(describing: error))
        }

        guard let document = dictionary(from: root) else {
            throw SubscriptionParserError.invalidYAML(detail: "top-level value is not a mapping")
        }
        guard let proxies = document["proxies"] as? [Any] else {
            throw SubscriptionParserError.missingProxiesSection
        }

        var nodes: [ProxyNode] = []
        var warnings: [String] = []

        for (index, entry) in proxies.enumerated() {
            guard let proxy = dictionary(from: entry) else {
                warnings.append("Skipped proxy #\(index + 1): entry is not a mapping.")
                continue
            }
            do {
                nodes.append(try node(from: proxy, index: index))
            } catch let error as EntryError {
                warnings.append(error.message)
            }
        }

        return SubscriptionParseResult(nodes: nodes, warnings: warnings)
    }

    // MARK: - Per-entry mapping

    /// Internal error used to bubble a skip reason out of the field mappers.
    private struct EntryError: Error {
        let message: String
    }

    private func node(from proxy: [String: Any], index: Int) throws -> ProxyNode {
        let displayName = string(proxy["name"]) ?? "#\(index + 1)"

        guard let typeString = string(proxy["type"]) else {
            throw EntryError(message: "Skipped \"\(displayName)\": missing \"type\".")
        }
        guard let protocolType = NodeProtocol(rawValue: typeString) else {
            throw EntryError(message: "Skipped \"\(displayName)\": unsupported type \"\(typeString)\".")
        }
        guard let name = string(proxy["name"]), !name.isEmpty else {
            throw EntryError(message: "Skipped \"\(displayName)\": missing \"name\".")
        }
        guard let server = string(proxy["server"]), !server.isEmpty else {
            throw EntryError(message: "Skipped \"\(name)\": missing \"server\".")
        }
        guard let port = integer(proxy["port"]), (1...65535).contains(port) else {
            throw EntryError(message: "Skipped \"\(name)\": missing or invalid \"port\".")
        }

        let sni = string(proxy["sni"]) ?? string(proxy["servername"])
        let allowInsecure = bool(proxy["skip-cert-verify"]) ?? false

        switch protocolType {
        case .shadowsocks:
            guard let method = string(proxy["cipher"]), !method.isEmpty else {
                throw EntryError(message: "Skipped \"\(name)\": ss entry missing \"cipher\".")
            }
            guard let password = string(proxy["password"]), !password.isEmpty else {
                throw EntryError(message: "Skipped \"\(name)\": ss entry missing \"password\".")
            }
            return ProxyNode(
                name: name,
                protocolType: .shadowsocks,
                server: server,
                port: port,
                password: password,
                method: method
            )

        case .vmess:
            guard let uuid = string(proxy["uuid"]), !uuid.isEmpty else {
                throw EntryError(message: "Skipped \"\(name)\": vmess entry missing \"uuid\".")
            }
            return ProxyNode(
                name: name,
                protocolType: .vmess,
                server: server,
                port: port,
                uuid: uuid,
                alterId: integer(proxy["alterId"]) ?? 0,
                tlsEnabled: bool(proxy["tls"]) ?? false,
                sni: sni,
                allowInsecure: allowInsecure
            )

        case .trojan:
            guard let password = string(proxy["password"]), !password.isEmpty else {
                throw EntryError(message: "Skipped \"\(name)\": trojan entry missing \"password\".")
            }
            return ProxyNode(
                name: name,
                protocolType: .trojan,
                server: server,
                port: port,
                password: password,
                tlsEnabled: true,
                sni: sni,
                allowInsecure: allowInsecure
            )

        case .vless:
            guard let uuid = string(proxy["uuid"]), !uuid.isEmpty else {
                throw EntryError(message: "Skipped \"\(name)\": vless entry missing \"uuid\".")
            }
            return ProxyNode(
                name: name,
                protocolType: .vless,
                server: server,
                port: port,
                uuid: uuid,
                flow: string(proxy["flow"]),
                tlsEnabled: bool(proxy["tls"]) ?? false,
                sni: sni,
                allowInsecure: allowInsecure
            )

        case .hysteria2:
            guard let password = string(proxy["password"]), !password.isEmpty else {
                throw EntryError(message: "Skipped \"\(name)\": hysteria2 entry missing \"password\".")
            }
            return ProxyNode(
                name: name,
                protocolType: .hysteria2,
                server: server,
                port: port,
                password: password,
                tlsEnabled: true,
                sni: sni,
                allowInsecure: allowInsecure
            )

        case .tuic:
            guard let uuid = string(proxy["uuid"]), !uuid.isEmpty else {
                throw EntryError(message: "Skipped \"\(name)\": tuic entry missing \"uuid\".")
            }
            return ProxyNode(
                name: name,
                protocolType: .tuic,
                server: server,
                port: port,
                password: string(proxy["password"]),
                uuid: uuid,
                tlsEnabled: true,
                sni: sni,
                allowInsecure: allowInsecure
            )
        }
    }

    // MARK: - YAML value coercion

    private func dictionary(from value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            return dict
        }
        if let dict = value as? [AnyHashable: Any] {
            var result: [String: Any] = [:]
            for (key, entry) in dict {
                guard let key = key as? String else { continue }
                result[key] = entry
            }
            return result
        }
        return nil
    }

    private func string(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let int = value as? Int {
            return String(int)
        }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes":
                return true
            case "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
