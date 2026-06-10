import Foundation

/// Builds the per-node `outbounds[]` entry, including the shared `tls`
/// (server_name/insecure/alpn/utls/reality) and `transport` (ws/grpc/http/
/// httpupgrade) blocks and the shadowsocks `plugin`/`plugin_opts` fields.
///
/// Field names verified against:
/// - https://sing-box.sagernet.org/configuration/outbound/shadowsocks/
/// - https://sing-box.sagernet.org/configuration/outbound/vmess/
/// - https://sing-box.sagernet.org/configuration/outbound/vless/
/// - https://sing-box.sagernet.org/configuration/shared/tls/
/// - https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
struct OutboundBuilder {
    /// Builds the JSON object for a single node's outbound.
    func outbound(for node: ProxyNode, tag: String) throws -> [String: Any] {
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
            applyShadowsocksPlugin(node, into: &outbound)

        case .vmess:
            outbound["uuid"] = try require(node.uuid, field: "uuid", node: node)
            outbound["security"] = "auto"
            outbound["alter_id"] = node.alterId ?? 0
            applyTLSIfNeeded(node, mandatory: false, into: &outbound)
            applyTransport(node, into: &outbound)

        case .vless:
            outbound["uuid"] = try require(node.uuid, field: "uuid", node: node)
            if let flow = node.flow, !flow.isEmpty {
                outbound["flow"] = flow
            }
            applyTLSIfNeeded(node, mandatory: false, into: &outbound)
            applyTransport(node, into: &outbound)

        case .trojan:
            outbound["password"] = try require(node.password, field: "password", node: node)
            // Trojan always runs over TLS.
            applyTLSIfNeeded(node, mandatory: true, into: &outbound)
            applyTransport(node, into: &outbound)

        case .hysteria2:
            outbound["password"] = try require(node.password, field: "password", node: node)
            // Hysteria2 runs over QUIC, which always uses TLS.
            applyTLSIfNeeded(node, mandatory: true, into: &outbound)

        case .tuic:
            outbound["uuid"] = try require(node.uuid, field: "uuid", node: node)
            if let password = node.password, !password.isEmpty {
                outbound["password"] = password
            }
            // TUIC runs over QUIC, which always uses TLS.
            applyTLSIfNeeded(node, mandatory: true, into: &outbound)

        case .ssh:
            try applySSH(node, into: &outbound)

        case .wireguard:
            // WireGuard is a top-level `endpoint` in sing-box 1.11+, not an
            // outbound; the config builder emits it via `endpointObject(for:)`
            // into `endpoints[]`. It must never be produced here.
            throw SingBoxConfigError.wireGuardIsEndpoint(node: node.name)
        }

        return outbound
    }

    // MARK: - SSH

    /// Fills in the `ssh` outbound fields from `node.ssh`. Verified against
    /// https://sing-box.sagernet.org/configuration/outbound/ssh/
    private func applySSH(_ node: ProxyNode, into outbound: inout [String: Any]) throws {
        guard let ssh = node.ssh else {
            throw SingBoxConfigError.missingField(node: node.name, field: "ssh")
        }
        outbound["user"] = try require(ssh.user, field: "user", node: node)
        if let password = ssh.password, !password.isEmpty {
            outbound["password"] = password
        }
        if let key = ssh.privateKey, !key.isEmpty {
            outbound["private_key"] = key
        }
        if let path = ssh.privateKeyPath, !path.isEmpty {
            outbound["private_key_path"] = path
        }
        if let passphrase = ssh.privateKeyPassphrase, !passphrase.isEmpty {
            outbound["private_key_passphrase"] = passphrase
        }
        if !ssh.hostKey.isEmpty {
            outbound["host_key"] = ssh.hostKey
        }
        if !ssh.hostKeyAlgorithms.isEmpty {
            outbound["host_key_algorithms"] = ssh.hostKeyAlgorithms
        }
        if let version = ssh.clientVersion, !version.isEmpty {
            outbound["client_version"] = version
        }
    }

    // MARK: - WireGuard endpoint

    /// Builds the top-level `endpoints[]` entry for a WireGuard node. Verified
    /// against https://sing-box.sagernet.org/configuration/endpoint/wireguard/
    /// (WireGuard migrated from an outbound to an endpoint in sing-box 1.11+;
    /// the `tag` stays referenceable by rules/groups exactly like an outbound).
    func endpointObject(for node: ProxyNode, tag: String) throws -> [String: Any] {
        guard let wg = node.wireGuard else {
            throw SingBoxConfigError.missingField(node: node.name, field: "wireguard")
        }
        // sing-box accepts an empty interface address[] but the tunnel then
        // routes nothing — a silent dead tunnel. Reject it at build time so the
        // pre-flight validator surfaces it instead of failing invisibly.
        let addresses = wg.localAddresses.filter { !$0.isEmpty }
        guard !addresses.isEmpty else {
            throw SingBoxConfigError.missingField(node: node.name, field: "wireguard.address")
        }
        var endpoint: [String: Any] = [
            "type": node.protocolType.singBoxOutboundType,
            "tag": tag,
            "address": addresses,
            "private_key": try require(wg.privateKey, field: "private_key", node: node),
        ]
        if let mtu = wg.mtu, mtu > 0 {
            endpoint["mtu"] = mtu
        }

        var peer: [String: Any] = [
            "address": node.server,
            "port": node.port,
            "public_key": try require(wg.peerPublicKey, field: "peer_public_key", node: node),
        ]
        if let psk = wg.preSharedKey, !psk.isEmpty {
            peer["pre_shared_key"] = psk
        }
        // A peer with no allowed_ips would route nothing; default to catch-all.
        peer["allowed_ips"] = ["0.0.0.0/0", "::/0"]
        if let keepalive = wg.persistentKeepalive, keepalive > 0 {
            peer["persistent_keepalive_interval"] = keepalive
        }
        if !wg.reserved.isEmpty {
            peer["reserved"] = Array(wg.reserved.prefix(3))
        }
        endpoint["peers"] = [peer]

        return endpoint
    }

    // MARK: - TLS

    /// Emits the `tls` object when the protocol mandates it or the node opts in.
    private func applyTLSIfNeeded(_ node: ProxyNode, mandatory: Bool, into outbound: inout [String: Any]) {
        guard mandatory || node.tls.enabled || node.tlsEnabled else { return }
        outbound["tls"] = tlsObject(for: node)
    }

    /// Builds the `tls` object from the authoritative `node.tls`, falling back to
    /// the legacy mirror flags for server name / insecure when `tls` is at its
    /// defaults (so editors that only set the legacy flags keep working).
    func tlsObject(for node: ProxyNode) -> [String: Any] {
        let options = node.tls
        var tls: [String: Any] = ["enabled": true]

        let serverName = options.serverName ?? node.sni
        if let serverName, !serverName.isEmpty {
            tls["server_name"] = serverName
        }

        if options.insecure || node.allowInsecure {
            tls["insecure"] = true
        }

        if !options.alpn.isEmpty {
            tls["alpn"] = options.alpn
        }

        if let fingerprint = options.utlsFingerprint {
            tls["utls"] = [
                "enabled": true,
                "fingerprint": fingerprint.rawValue,
            ]
        }

        if let reality = options.reality, reality.enabled, !reality.publicKey.isEmpty {
            var realityObject: [String: Any] = [
                "enabled": true,
                "public_key": reality.publicKey,
            ]
            if !reality.shortID.isEmpty {
                realityObject["short_id"] = reality.shortID
            }
            tls["reality"] = realityObject
        }

        return tls
    }

    // MARK: - Transport

    /// Emits the v2ray `transport` block for ws/grpc/http/httpupgrade. TCP
    /// transports emit nothing (the protocol default).
    private func applyTransport(_ node: ProxyNode, into outbound: inout [String: Any]) {
        guard let transport = transportObject(for: node.transport) else { return }
        outbound["transport"] = transport
    }

    /// Builds the `transport` object, or `nil` for plain TCP.
    func transportObject(for transport: TransportOptions) -> [String: Any]? {
        switch transport.type {
        case .tcp:
            return nil

        case .ws:
            var ws: [String: Any] = ["type": "ws"]
            if let path = transport.path, !path.isEmpty {
                ws["path"] = path
            }
            // ws carries the Host as a request header; merge an explicit
            // `host` entry into headers without clobbering a user-set Host.
            var headers = transport.headers
            if let host = transport.host.first, !host.isEmpty, headers["Host"] == nil {
                headers["Host"] = host
            }
            if !headers.isEmpty {
                ws["headers"] = headers
            }
            return ws

        case .grpc:
            var grpc: [String: Any] = ["type": "grpc"]
            if let serviceName = transport.serviceName, !serviceName.isEmpty {
                grpc["service_name"] = serviceName
            }
            return grpc

        case .http:
            var http: [String: Any] = ["type": "http"]
            // http `host` is an array of domains.
            let hosts = transport.host.filter { !$0.isEmpty }
            if !hosts.isEmpty {
                http["host"] = hosts
            }
            if let path = transport.path, !path.isEmpty {
                http["path"] = path
            }
            if !transport.headers.isEmpty {
                http["headers"] = transport.headers
            }
            return http

        case .httpUpgrade:
            var upgrade: [String: Any] = ["type": "httpupgrade"]
            // httpupgrade `host` is a single string.
            if let host = transport.host.first, !host.isEmpty {
                upgrade["host"] = host
            }
            if let path = transport.path, !path.isEmpty {
                upgrade["path"] = path
            }
            if !transport.headers.isEmpty {
                upgrade["headers"] = transport.headers
            }
            return upgrade
        }
    }

    // MARK: - shadowsocks plugin

    private func applyShadowsocksPlugin(_ node: ProxyNode, into outbound: inout [String: Any]) {
        guard let plugin = node.plugin, !plugin.isEmpty else { return }
        outbound["plugin"] = plugin
        if let opts = node.pluginOpts, !opts.isEmpty {
            outbound["plugin_opts"] = opts
        }
    }

    // MARK: - Helpers

    private func require(_ value: String?, field: String, node: ProxyNode) throws -> String {
        guard let value, !value.isEmpty else {
            throw SingBoxConfigError.missingField(node: node.name, field: field)
        }
        return value
    }
}
