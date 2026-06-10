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
///
/// Beyond the basic credentials, the parser carries the full transport and
/// security surface so that nodes actually connect:
/// - TLS: `tls`/`servername`/`sni`/`skip-cert-verify`/`alpn`/`client-fingerprint`
/// - REALITY: `reality-opts.public-key` / `reality-opts.short-id`
/// - transport: `network` + `ws-opts` / `grpc-opts` / `h2-opts` / `http-opts`
/// - shadowsocks SIP003: `plugin` + `plugin-opts`
/// - hysteria2 extras (`up`/`down`/`obfs`/`obfs-password`) and tuic extras
///   (`congestion-controller`/`udp-relay-mode`) are folded into `pluginOpts`
///   as a stable `key=value;` carrier the config builder can re-emit.
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

        switch protocolType {
        case .shadowsocks:
            return try shadowsocksNode(proxy, name: name, server: server, port: port)
        case .vmess:
            return try vmessNode(proxy, name: name, server: server, port: port)
        case .trojan:
            return try trojanNode(proxy, name: name, server: server, port: port)
        case .vless:
            return try vlessNode(proxy, name: name, server: server, port: port)
        case .hysteria2:
            return try hysteria2Node(proxy, name: name, server: server, port: port)
        case .tuic:
            return try tuicNode(proxy, name: name, server: server, port: port)
        }
    }

    // MARK: - Protocol mappers

    private func shadowsocksNode(
        _ proxy: [String: Any], name: String, server: String, port: Int
    ) throws -> ProxyNode {
        guard let method = string(proxy["cipher"]), !method.isEmpty else {
            throw EntryError(message: "Skipped \"\(name)\": ss entry missing \"cipher\".")
        }
        guard let password = string(proxy["password"]), !password.isEmpty else {
            throw EntryError(message: "Skipped \"\(name)\": ss entry missing \"password\".")
        }
        let (plugin, pluginOpts) = shadowsocksPlugin(proxy)
        let tls = buildTLS(proxy, mandatory: false)
        return ProxyNode(
            name: name,
            protocolType: .shadowsocks,
            server: server,
            port: port,
            password: password,
            method: method,
            tlsEnabled: tls.enabled,
            sni: tls.serverName,
            allowInsecure: tls.insecure,
            tls: tls,
            transport: buildTransport(proxy),
            plugin: plugin,
            pluginOpts: pluginOpts
        )
    }

    private func vmessNode(
        _ proxy: [String: Any], name: String, server: String, port: Int
    ) throws -> ProxyNode {
        guard let uuid = string(proxy["uuid"]), !uuid.isEmpty else {
            throw EntryError(message: "Skipped \"\(name)\": vmess entry missing \"uuid\".")
        }
        let tls = buildTLS(proxy, mandatory: false)
        return ProxyNode(
            name: name,
            protocolType: .vmess,
            server: server,
            port: port,
            uuid: uuid,
            alterId: integer(proxy["alterId"]) ?? 0,
            tlsEnabled: tls.enabled,
            sni: tls.serverName,
            allowInsecure: tls.insecure,
            tls: tls,
            transport: buildTransport(proxy)
        )
    }

    private func trojanNode(
        _ proxy: [String: Any], name: String, server: String, port: Int
    ) throws -> ProxyNode {
        guard let password = string(proxy["password"]), !password.isEmpty else {
            throw EntryError(message: "Skipped \"\(name)\": trojan entry missing \"password\".")
        }
        // Trojan always runs over TLS.
        let tls = buildTLS(proxy, mandatory: true)
        return ProxyNode(
            name: name,
            protocolType: .trojan,
            server: server,
            port: port,
            password: password,
            tlsEnabled: true,
            sni: tls.serverName,
            allowInsecure: tls.insecure,
            tls: tls,
            transport: buildTransport(proxy)
        )
    }

    private func vlessNode(
        _ proxy: [String: Any], name: String, server: String, port: Int
    ) throws -> ProxyNode {
        guard let uuid = string(proxy["uuid"]), !uuid.isEmpty else {
            throw EntryError(message: "Skipped \"\(name)\": vless entry missing \"uuid\".")
        }
        // REALITY implies TLS even when `tls:` is absent in the Clash entry.
        let realityPresent = dictionary(from: proxy["reality-opts"]) != nil
        let tls = buildTLS(proxy, mandatory: realityPresent)
        return ProxyNode(
            name: name,
            protocolType: .vless,
            server: server,
            port: port,
            uuid: uuid,
            flow: string(proxy["flow"]),
            tlsEnabled: tls.enabled,
            sni: tls.serverName,
            allowInsecure: tls.insecure,
            tls: tls,
            transport: buildTransport(proxy)
        )
    }

    private func hysteria2Node(
        _ proxy: [String: Any], name: String, server: String, port: Int
    ) throws -> ProxyNode {
        guard let password = string(proxy["password"]), !password.isEmpty else {
            throw EntryError(message: "Skipped \"\(name)\": hysteria2 entry missing \"password\".")
        }
        // Hysteria2 runs over QUIC, which always uses TLS.
        let tls = buildTLS(proxy, mandatory: true)
        return ProxyNode(
            name: name,
            protocolType: .hysteria2,
            server: server,
            port: port,
            password: password,
            tlsEnabled: true,
            sni: tls.serverName,
            allowInsecure: tls.insecure,
            tls: tls,
            pluginOpts: hysteria2Extras(proxy)
        )
    }

    private func tuicNode(
        _ proxy: [String: Any], name: String, server: String, port: Int
    ) throws -> ProxyNode {
        guard let uuid = string(proxy["uuid"]), !uuid.isEmpty else {
            throw EntryError(message: "Skipped \"\(name)\": tuic entry missing \"uuid\".")
        }
        // TUIC runs over QUIC, which always uses TLS.
        let tls = buildTLS(proxy, mandatory: true)
        return ProxyNode(
            name: name,
            protocolType: .tuic,
            server: server,
            port: port,
            password: string(proxy["password"]),
            uuid: uuid,
            tlsEnabled: true,
            sni: tls.serverName,
            allowInsecure: tls.insecure,
            tls: tls,
            pluginOpts: tuicExtras(proxy)
        )
    }

    // MARK: - TLS / REALITY

    /// Builds `TLSOptions` from the Clash security keys. `mandatory` forces
    /// `enabled` for protocols that always run over TLS (trojan/hysteria2/tuic)
    /// or when REALITY is present.
    private func buildTLS(_ proxy: [String: Any], mandatory: Bool) -> TLSOptions {
        let enabled = mandatory || (bool(proxy["tls"]) ?? false)
        let serverName = string(proxy["sni"]) ?? string(proxy["servername"])
        let insecure = bool(proxy["skip-cert-verify"]) ?? false
        let alpn = stringList(proxy["alpn"])
        let fingerprint = utlsFingerprint(string(proxy["client-fingerprint"]))
        let reality = realityOptions(proxy)

        return TLSOptions(
            enabled: enabled,
            serverName: serverName,
            insecure: insecure,
            alpn: alpn,
            utlsFingerprint: fingerprint,
            reality: reality
        )
    }

    private func realityOptions(_ proxy: [String: Any]) -> RealityOptions? {
        guard let opts = dictionary(from: proxy["reality-opts"]) else { return nil }
        let publicKey = string(opts["public-key"]) ?? ""
        guard !publicKey.isEmpty else { return nil }
        let shortID = string(opts["short-id"]) ?? ""
        return RealityOptions(enabled: true, publicKey: publicKey, shortID: shortID)
    }

    /// Maps a Clash `client-fingerprint` value to a `UTLSFingerprint`. Clash
    /// `random`/`randomized` map directly; unknown values yield `nil`.
    private func utlsFingerprint(_ raw: String?) -> UTLSFingerprint? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        return UTLSFingerprint(rawValue: raw)
    }

    // MARK: - Transport

    /// Reads `network` + transport-specific option mappings into
    /// `TransportOptions`. Returns `.tcp` for missing/`tcp`/unknown networks.
    private func buildTransport(_ proxy: [String: Any]) -> TransportOptions {
        let network = string(proxy["network"])?.lowercased() ?? "tcp"
        switch network {
        case "ws":
            return wsTransport(proxy)
        case "grpc":
            return grpcTransport(proxy)
        case "h2", "http":
            return httpTransport(proxy)
        default:
            return .tcp
        }
    }

    private func wsTransport(_ proxy: [String: Any]) -> TransportOptions {
        let opts = dictionary(from: proxy["ws-opts"]) ?? [:]
        let path = string(opts["path"])
        var headers = stringHeaders(opts["headers"])
        // Clash carries the WS Host as a `Host` header; promote it to
        // `transport.host` and drop it from the literal header map.
        var host: [String] = []
        if let hostHeader = headerValue(headers, key: "Host") {
            host = [hostHeader]
            headers = removingHeader(headers, key: "Host")
        }
        return TransportOptions(
            type: .ws,
            path: path,
            headers: headers,
            host: host
        )
    }

    private func grpcTransport(_ proxy: [String: Any]) -> TransportOptions {
        let opts = dictionary(from: proxy["grpc-opts"]) ?? [:]
        let serviceName = string(opts["grpc-service-name"])
        return TransportOptions(type: .grpc, serviceName: serviceName)
    }

    private func httpTransport(_ proxy: [String: Any]) -> TransportOptions {
        // Clash uses `h2-opts` for h2 and `http-opts` for http; accept both.
        let opts = dictionary(from: proxy["h2-opts"])
            ?? dictionary(from: proxy["http-opts"])
            ?? [:]
        let path = string(opts["path"])
        let host = stringList(opts["host"])
        let headers = stringHeaders(opts["headers"])
        return TransportOptions(
            type: .http,
            path: path,
            headers: headers,
            host: host
        )
    }

    // MARK: - shadowsocks SIP003 plugin

    /// Flattens Clash `plugin` + `plugin-opts` into a `(plugin, pluginOpts)`
    /// pair. `pluginOpts` is the SIP003 `key=value;key;` string sing-box
    /// expects (e.g. `obfs=http;obfs-host=bing.com`).
    private func shadowsocksPlugin(_ proxy: [String: Any]) -> (String?, String?) {
        guard let plugin = string(proxy["plugin"]), !plugin.isEmpty else {
            return (nil, nil)
        }
        let opts = dictionary(from: proxy["plugin-opts"]) ?? [:]
        var pairs: [String] = []

        switch plugin {
        case "obfs", "obfs-local", "simple-obfs":
            if let mode = string(opts["mode"]) { pairs.append("obfs=\(mode)") }
            if let host = string(opts["host"]) { pairs.append("obfs-host=\(host)") }
            return ("obfs-local", pairs.isEmpty ? nil : pairs.joined(separator: ";"))
        case "v2ray-plugin":
            if let mode = string(opts["mode"]) { pairs.append("mode=\(mode)") }
            if bool(opts["tls"]) == true { pairs.append("tls") }
            if let host = string(opts["host"]) { pairs.append("host=\(host)") }
            if let path = string(opts["path"]) { pairs.append("path=\(path)") }
            return ("v2ray-plugin", pairs.isEmpty ? nil : pairs.joined(separator: ";"))
        default:
            // Unknown plugin — carry it verbatim with a flattened opts string.
            for (key, value) in opts.sorted(by: { $0.key < $1.key }) {
                if let value = string(value) {
                    pairs.append("\(key)=\(value)")
                }
            }
            return (plugin, pairs.isEmpty ? nil : pairs.joined(separator: ";"))
        }
    }

    // MARK: - hysteria2 / tuic extras

    /// Folds hysteria2-only fields into a `key=value;` carrier string. The
    /// model has no dedicated fields for these, so the builder reconstructs
    /// them from `pluginOpts`.
    private func hysteria2Extras(_ proxy: [String: Any]) -> String? {
        var pairs: [String] = []
        if let up = string(proxy["up"]) { pairs.append("up=\(up)") }
        if let down = string(proxy["down"]) { pairs.append("down=\(down)") }
        if let obfs = string(proxy["obfs"]), !obfs.isEmpty {
            pairs.append("obfs=\(obfs)")
            if let pw = string(proxy["obfs-password"]) { pairs.append("obfs-password=\(pw)") }
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: ";")
    }

    /// Folds tuic-only fields into a `key=value;` carrier string.
    private func tuicExtras(_ proxy: [String: Any]) -> String? {
        var pairs: [String] = []
        if let cc = string(proxy["congestion-controller"]) {
            pairs.append("congestion-control=\(cc)")
        }
        if let mode = string(proxy["udp-relay-mode"]) {
            pairs.append("udp-relay-mode=\(mode)")
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: ";")
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

    /// Coerces a YAML scalar or sequence into `[String]`. Single scalars become
    /// a one-element list; non-string elements are dropped.
    private func stringList(_ value: Any?) -> [String] {
        if let array = value as? [Any] {
            return array.compactMap { string($0) }
        }
        if let single = string(value) {
            return [single]
        }
        return []
    }

    /// Coerces a YAML mapping of header name -> value into `[String: String]`,
    /// flattening list values to their first entry (Clash sometimes wraps
    /// header values in a single-element array).
    private func stringHeaders(_ value: Any?) -> [String: String] {
        guard let dict = dictionary(from: value) else { return [:] }
        var result: [String: String] = [:]
        for (key, raw) in dict {
            if let value = string(raw) {
                result[key] = value
            } else if let list = raw as? [Any], let first = list.compactMap({ string($0) }).first {
                result[key] = first
            }
        }
        return result
    }

    /// Case-insensitive header lookup (HTTP header names are case-insensitive).
    private func headerValue(_ headers: [String: String], key: String) -> String? {
        if let exact = headers[key] { return exact }
        let lowered = key.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }

    private func removingHeader(_ headers: [String: String], key: String) -> [String: String] {
        let lowered = key.lowercased()
        return headers.filter { $0.key.lowercased() != lowered }
    }
}
