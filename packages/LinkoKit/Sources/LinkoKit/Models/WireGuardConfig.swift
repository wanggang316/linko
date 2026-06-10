import Foundation

/// WireGuard parameters, carried on a `ProxyNode` whose `protocolType` is
/// `.wireguard`. Maps to a sing-box 1.13 top-level `endpoints[]` entry of
/// `type: "wireguard"` (WireGuard migrated from an outbound to an endpoint in
/// sing-box 1.11+).
///
/// Field names verified against
/// https://sing-box.sagernet.org/configuration/endpoint/wireguard/
///
/// The endpoint's `tag`, `mtu`, and interface `address` come from the owning
/// `ProxyNode` (`name`/`mtu`) and this struct (`localAddresses`); the single
/// peer is built from `ProxyNode.server`/`port` plus the fields here. Optional
/// fields are tolerantly decoded so configs persisted before this milestone — or
/// partial subscription entries — still load (skip-don't-crash).
public struct WireGuardConfig: Codable, Hashable, Sendable {
    /// Interface `private_key` (base64). The local peer's private key.
    public var privateKey: String
    /// The remote peer's `public_key` (base64).
    public var peerPublicKey: String
    /// Optional `pre_shared_key` (base64); empty ⇒ omitted.
    public var preSharedKey: String?
    /// Interface `address[]` — the local tunnel addresses, e.g.
    /// `["10.0.0.2/32", "fd00::2/128"]`. At least one is required: an empty
    /// list is tolerated on decode but the config builder throws
    /// `missingField("wireguard.address")` so a dead tunnel can't ship silently.
    public var localAddresses: [String]
    /// Peer `reserved` — three bytes some providers (e.g. Cloudflare WARP)
    /// require. Empty ⇒ omitted. Non-empty lists are clamped to three entries
    /// by the builder.
    public var reserved: [Int]
    /// Interface `mtu`; `nil` ⇒ the sing-box default (1408) is used.
    public var mtu: Int?
    /// Peer `persistent_keepalive_interval` in seconds; `nil`/`0` ⇒ omitted.
    public var persistentKeepalive: Int?

    public init(
        privateKey: String = "",
        peerPublicKey: String = "",
        preSharedKey: String? = nil,
        localAddresses: [String] = [],
        reserved: [Int] = [],
        mtu: Int? = nil,
        persistentKeepalive: Int? = nil
    ) {
        self.privateKey = privateKey
        self.peerPublicKey = peerPublicKey
        self.preSharedKey = preSharedKey
        self.localAddresses = localAddresses
        self.reserved = reserved
        self.mtu = mtu
        self.persistentKeepalive = persistentKeepalive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.privateKey = try c.decodeIfPresent(String.self, forKey: .privateKey) ?? ""
        self.peerPublicKey = try c.decodeIfPresent(String.self, forKey: .peerPublicKey) ?? ""
        self.preSharedKey = try c.decodeIfPresent(String.self, forKey: .preSharedKey)
        self.localAddresses = try c.decodeIfPresent([String].self, forKey: .localAddresses) ?? []
        self.reserved = try c.decodeIfPresent([Int].self, forKey: .reserved) ?? []
        self.mtu = try c.decodeIfPresent(Int.self, forKey: .mtu)
        self.persistentKeepalive = try c.decodeIfPresent(Int.self, forKey: .persistentKeepalive)
    }
}

/// SSH parameters, carried on a `ProxyNode` whose `protocolType` is `.ssh`.
/// Maps to a sing-box 1.13 `outbounds[]` entry of `type: "ssh"` (SSH remains a
/// regular outbound, not an endpoint).
///
/// Field names verified against
/// https://sing-box.sagernet.org/configuration/outbound/ssh/
///
/// `server`/`server_port`/`user` come from the owning `ProxyNode`
/// (`server`/`port`) and this struct (`user`). Authentication is by password OR
/// private key (`privateKey` inline, or `privateKeyPath` on disk, with optional
/// `privateKeyPassphrase`). `hostKey` pins the server's host key(s) like a
/// known-hosts entry. All fields are tolerantly decoded.
public struct SSHConfig: Codable, Hashable, Sendable {
    /// `user`.
    public var user: String
    /// `password`; `nil` ⇒ omitted. Provide this OR a private key.
    public var password: String?
    /// `private_key` — an inline PEM-encoded private key; `nil` ⇒ omitted.
    public var privateKey: String?
    /// `private_key_path` — a path to a private key on disk; `nil` ⇒ omitted.
    public var privateKeyPath: String?
    /// `private_key_passphrase` decrypting the private key; `nil` ⇒ omitted.
    public var privateKeyPassphrase: String?
    /// `host_key` — pinned server host key lines (known-hosts style). Empty ⇒
    /// omitted (host key is not verified).
    public var hostKey: [String]
    /// `host_key_algorithms`. Empty ⇒ omitted.
    public var hostKeyAlgorithms: [String]
    /// `client_version` banner; `nil` ⇒ the sing-box default is used.
    public var clientVersion: String?

    public init(
        user: String = "",
        password: String? = nil,
        privateKey: String? = nil,
        privateKeyPath: String? = nil,
        privateKeyPassphrase: String? = nil,
        hostKey: [String] = [],
        hostKeyAlgorithms: [String] = [],
        clientVersion: String? = nil
    ) {
        self.user = user
        self.password = password
        self.privateKey = privateKey
        self.privateKeyPath = privateKeyPath
        self.privateKeyPassphrase = privateKeyPassphrase
        self.hostKey = hostKey
        self.hostKeyAlgorithms = hostKeyAlgorithms
        self.clientVersion = clientVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        self.password = try c.decodeIfPresent(String.self, forKey: .password)
        self.privateKey = try c.decodeIfPresent(String.self, forKey: .privateKey)
        self.privateKeyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath)
        self.privateKeyPassphrase = try c.decodeIfPresent(String.self, forKey: .privateKeyPassphrase)
        self.hostKey = try c.decodeIfPresent([String].self, forKey: .hostKey) ?? []
        self.hostKeyAlgorithms = try c.decodeIfPresent([String].self, forKey: .hostKeyAlgorithms) ?? []
        self.clientVersion = try c.decodeIfPresent(String.self, forKey: .clientVersion)
    }
}
