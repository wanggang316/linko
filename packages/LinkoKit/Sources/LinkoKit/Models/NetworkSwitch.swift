import Foundation

/// The kind of network interface currently carrying the default route. Used by
/// `NetworkSwitchRule` to switch profiles by environment (e.g. "wired at the
/// office, Wi-Fi at home").
public enum NetworkInterfaceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case wifi
    case wired
    case cellular
    case other

    public var displayName: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .wired: return "有线"
        case .cellular: return "蜂窝"
        case .other: return "其他"
        }
    }
}

/// A rule that maps a network condition to a profile. When the active network
/// matches, linko switches to `profileID`. This is the app-level realization of
/// Surge's `SUBNET` / network-based policy switching: sing-box has no such
/// primitive, so the client evaluates it against the live network and swaps the
/// whole profile.
///
/// Flat (kind + value) rather than an enum-with-payload so the on-disk JSON is
/// simple and the decoder stays tolerant, matching the rest of the model layer.
public struct NetworkSwitchRule: Codable, Hashable, Identifiable, Sendable {
    /// What the rule matches on.
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        /// The device's local IPv4 address falls inside `value` (a CIDR like
        /// `192.168.1.0/24`). This is the literal "SUBNET" match.
        case subnet
        /// The default route runs over an interface of `value`'s kind
        /// (`NetworkInterfaceKind.rawValue`).
        case interface
    }

    public var id: UUID
    public var kind: Kind
    /// CIDR for `.subnet`; a `NetworkInterfaceKind.rawValue` for `.interface`.
    public var value: String
    /// The profile to switch to when this rule matches.
    public var profileID: UUID
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind = .subnet,
        value: String = "",
        profileID: UUID,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.profileID = profileID
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .subnet
        self.value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        // A rule with no profile is meaningless; tolerate it by decoding a zero
        // UUID, which the evaluator's existence check will simply never match.
        self.profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// The global network-based auto-switch configuration. Lives outside any single
/// `Profile` (it selects *between* profiles) and is persisted on its own as
/// `network-switch.json`.
public struct NetworkSwitchConfig: Codable, Hashable, Sendable {
    /// Master switch. When off, the monitor never triggers a profile change.
    public var isEnabled: Bool
    /// Ordered rules; the first enabled rule that matches the current network
    /// wins (so put more specific subnets above broad interface rules).
    public var rules: [NetworkSwitchRule]

    public init(isEnabled: Bool = false, rules: [NetworkSwitchRule] = []) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    public static let disabled = NetworkSwitchConfig()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.rules = try c.decodeIfPresent([NetworkSwitchRule].self, forKey: .rules) ?? []
    }
}

/// A snapshot of the current network environment, produced by the platform
/// monitor and fed to `NetworkSwitchEvaluator`. Pure data so the matching logic
/// is fully testable without any live networking.
public struct NetworkSnapshot: Equatable, Sendable {
    public var interface: NetworkInterfaceKind
    /// Local IPv4 addresses of active interfaces (e.g. `["192.168.1.42"]`).
    public var ipv4Addresses: [String]

    public init(interface: NetworkInterfaceKind, ipv4Addresses: [String]) {
        self.interface = interface
        self.ipv4Addresses = ipv4Addresses
    }
}

/// Stateless evaluator: resolves which profile a network snapshot maps to under
/// a set of rules. First enabled matching rule wins; returns `nil` when nothing
/// matches (in which case the caller leaves the active profile untouched).
public enum NetworkSwitchEvaluator {
    public static func matchedProfileID(
        rules: [NetworkSwitchRule],
        snapshot: NetworkSnapshot
    ) -> UUID? {
        for rule in rules where rule.isEnabled {
            if matches(rule, snapshot) {
                return rule.profileID
            }
        }
        return nil
    }

    static func matches(_ rule: NetworkSwitchRule, _ snapshot: NetworkSnapshot) -> Bool {
        switch rule.kind {
        case .interface:
            return rule.value.trimmingCharacters(in: .whitespaces).lowercased()
                == snapshot.interface.rawValue
        case .subnet:
            let cidr = rule.value.trimmingCharacters(in: .whitespaces)
            guard !cidr.isEmpty else { return false }
            return snapshot.ipv4Addresses.contains { ipv4($0, inCIDR: cidr) }
        }
    }

    // MARK: - IPv4 CIDR matching

    /// Whether `ip` (a dotted IPv4 literal) falls within `cidr` (`a.b.c.d/n`,
    /// or a bare address ⇒ `/32`). IPv6 is not matched (returns `false`).
    static func ipv4(_ ip: String, inCIDR cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
        guard let network = ipv4ToUInt32(parts[0]) else { return false }
        let prefix: Int
        if parts.count == 2 {
            guard let p = Int(parts[1]), (0...32).contains(p) else { return false }
            prefix = p
        } else {
            prefix = 32
        }
        guard let address = ipv4ToUInt32(ip) else { return false }
        if prefix == 0 { return true }
        let mask: UInt32 = 0xFFFF_FFFF << (32 - prefix)
        return (address & mask) == (network & mask)
    }

    /// Parses a dotted IPv4 literal into a host-order 32-bit value, or `nil`.
    static func ipv4ToUInt32(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard s.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }
}
