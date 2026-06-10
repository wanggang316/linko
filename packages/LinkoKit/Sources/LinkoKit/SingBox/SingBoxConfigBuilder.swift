import Foundation

/// Errors produced while turning `ProxyNode`s into a sing-box configuration.
public enum SingBoxConfigError: Error, Equatable, LocalizedError {
    case noNodes
    case missingField(node: String, field: String)

    public var errorDescription: String? {
        switch self {
        case .noNodes:
            return "Cannot build a sing-box config without any proxy nodes."
        case let .missingField(node, field):
            return "Node \"\(node)\" is missing the required field \"\(field)\"."
        }
    }
}

/// Builds a complete sing-box 1.x JSON configuration from proxy nodes and
/// user preferences. See `SingBoxConfigBuilding` for the produced shape.
public struct SingBoxConfigBuilder: SingBoxConfigBuilding {
    /// Tags reserved for non-node outbounds; node tags must never collide
    /// with these.
    private static let reservedTags: Set<String> = ["proxy", "direct"]

    public init() {}

    /// Returns the outbound tag assigned to each node, positionally aligned
    /// with `nodes` — the exact assignment `build` uses. Callers must address
    /// nodes through the Clash API by these tags, because display names may
    /// collide and get deduplicated here.
    public func outboundTags(for nodes: [ProxyNode]) -> [String] {
        var usedTags = Self.reservedTags
        return nodes.map { uniqueTag(for: $0.name, used: &usedTags) }
    }

    public func build(nodes: [ProxyNode], preferences: AppPreferences) throws -> Data {
        guard !nodes.isEmpty else {
            throw SingBoxConfigError.noNodes
        }

        let nodeTags = outboundTags(for: nodes)
        var nodeOutbounds: [[String: Any]] = []
        var selectedTag: String?

        for (node, tag) in zip(nodes, nodeTags) {
            nodeOutbounds.append(try outbound(for: node, tag: tag))
            if let selectedID = preferences.selectedNodeID, node.id == selectedID {
                selectedTag = tag
            }
        }

        var selector: [String: Any] = [
            "type": "selector",
            "tag": "proxy",
            "outbounds": nodeTags + ["direct"],
        ]
        if let selectedTag {
            selector["default"] = selectedTag
        }

        let direct: [String: Any] = ["type": "direct", "tag": "direct"]

        let config: [String: Any] = [
            "log": ["level": "info"],
            "inbounds": [
                [
                    "type": "mixed",
                    "tag": "mixed-in",
                    "listen": "127.0.0.1",
                    "listen_port": preferences.mixedPort,
                ]
            ],
            "outbounds": [selector] + nodeOutbounds + [direct],
            "route": ["final": "proxy"],
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:\(preferences.clashAPIPort)"
                ]
            ],
        ]

        return try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    // MARK: - Outbounds

    private func outbound(for node: ProxyNode, tag: String) throws -> [String: Any] {
        var outbound: [String: Any] = [
            "type": node.protocolType.singBoxOutboundType,
            "tag": tag,
            "server": node.server,
            "server_port": node.port,
        ]

        switch node.protocolType {
        case .shadowsocks:
            outbound["method"] = try require(node.method, field: "method", node: node)
            outbound["password"] = try require(node.password, field: "password", node: node)

        case .vmess:
            outbound["uuid"] = try require(node.uuid, field: "uuid", node: node)
            outbound["security"] = "auto"
            outbound["alter_id"] = node.alterId ?? 0
            if node.tlsEnabled {
                outbound["tls"] = tlsObject(for: node)
            }

        case .vless:
            outbound["uuid"] = try require(node.uuid, field: "uuid", node: node)
            if let flow = node.flow, !flow.isEmpty {
                outbound["flow"] = flow
            }
            if node.tlsEnabled {
                outbound["tls"] = tlsObject(for: node)
            }

        case .trojan:
            outbound["password"] = try require(node.password, field: "password", node: node)
            // Trojan always runs over TLS.
            outbound["tls"] = tlsObject(for: node)

        case .hysteria2:
            outbound["password"] = try require(node.password, field: "password", node: node)
            // Hysteria2 runs over QUIC, which always uses TLS.
            outbound["tls"] = tlsObject(for: node)

        case .tuic:
            outbound["uuid"] = try require(node.uuid, field: "uuid", node: node)
            if let password = node.password, !password.isEmpty {
                outbound["password"] = password
            }
            // TUIC runs over QUIC, which always uses TLS.
            outbound["tls"] = tlsObject(for: node)
        }

        return outbound
    }

    private func tlsObject(for node: ProxyNode) -> [String: Any] {
        var tls: [String: Any] = ["enabled": true]
        if let sni = node.sni, !sni.isEmpty {
            tls["server_name"] = sni
        }
        if node.allowInsecure {
            tls["insecure"] = true
        }
        return tls
    }

    // MARK: - Helpers

    private func require(_ value: String?, field: String, node: ProxyNode) throws -> String {
        guard let value, !value.isEmpty else {
            throw SingBoxConfigError.missingField(node: node.name, field: field)
        }
        return value
    }

    /// Returns a tag for `name` that does not collide with reserved tags or
    /// previously assigned node tags, appending a numeric suffix when needed.
    private func uniqueTag(for name: String, used: inout Set<String>) -> String {
        let base = name.isEmpty ? "node" : name
        var candidate = base
        var counter = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }
}
