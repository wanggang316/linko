import Foundation

/// The behavior of a policy group, mapped to a sing-box group outbound.
///
/// See https://sing-box.sagernet.org/configuration/outbound/selector/ and
/// https://sing-box.sagernet.org/configuration/outbound/urltest/
public enum GroupType: String, Codable, CaseIterable, Hashable, Sendable {
    /// Manual selection -> `{type:"selector"}`.
    case select
    /// Auto lowest-latency -> `{type:"urltest", url, interval, tolerance}`.
    case urlTest = "url-test"
    /// Failover -> degraded to `urltest` (sing-box has no distinct fallback
    /// type); members are tried in order via urltest semantics.
    case fallback
    /// Load balance -> sing-box has no native load-balance outbound; the
    /// builder degrades this to `urltest` and the UI surfaces a note.
    case loadBalance = "load-balance"

    /// The sing-box outbound `type` this group compiles to.
    public var singBoxOutboundType: String {
        switch self {
        case .select:
            return "selector"
        case .urlTest, .fallback, .loadBalance:
            return "urltest"
        }
    }

    /// `true` when the group needs the urltest tuning fields (url/interval/tolerance).
    public var usesURLTestParameters: Bool {
        self != .select
    }
}

/// A reference from a policy group to one of its members. A member is either a
/// proxy node (addressed by its outbound tag) or another policy group (nesting),
/// or one of the built-in outbounds ("direct" / "proxy").
///
/// Members are stored by *tag* (the stable outbound tag the config builder
/// assigns), not by `UUID`, so a group can reference built-ins and groups that
/// have no node identity. The engine resolves node tags via
/// `SingBoxConfigBuilding.outboundTags(for:)`.
public struct PolicyGroupMember: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case node
        case group
        /// A built-in outbound such as "direct" or "proxy".
        case builtin
    }

    public var kind: Kind
    /// The outbound tag of the referenced node/group/builtin.
    public var tag: String

    public var id: String { "\(kind.rawValue):\(tag)" }

    public init(kind: Kind, tag: String) {
        self.kind = kind
        self.tag = tag
    }

    public static func node(_ tag: String) -> PolicyGroupMember { .init(kind: .node, tag: tag) }
    public static func group(_ tag: String) -> PolicyGroupMember { .init(kind: .group, tag: tag) }
    public static func builtin(_ tag: String) -> PolicyGroupMember { .init(kind: .builtin, tag: tag) }
}

/// A policy group: a named selectable/auto-testing outbound that aggregates
/// nodes and/or other groups. Rules and `route.final` target group tags.
///
/// Groups can nest (a member of kind `.group`). The engine is responsible for
/// detecting and rejecting cycles; the model permits arbitrary references.
public struct PolicyGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Outbound tag and display name. Must be unique among groups and must not
    /// collide with node tags or reserved tags ("direct"). The default group is
    /// conventionally named "proxy".
    public var name: String
    public var type: GroupType
    /// Ordered members (nodes, nested groups, built-ins).
    public var members: [PolicyGroupMember]

    // MARK: url-test / fallback tuning (ignored for `.select`)

    /// `urltest.url` — the probe URL. `nil` ⇒ builder default.
    public var testURL: String?
    /// `urltest.interval`, e.g. "3m". `nil` ⇒ builder default.
    public var interval: String?
    /// `urltest.tolerance` in milliseconds. `nil` ⇒ builder default.
    public var tolerance: Int?

    /// Whether the user may delete/rename this group. The default "proxy"
    /// group is protected.
    public var isDefault: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        type: GroupType = .select,
        members: [PolicyGroupMember] = [],
        testURL: String? = nil,
        interval: String? = nil,
        tolerance: Int? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.members = members
        self.testURL = testURL
        self.interval = interval
        self.tolerance = tolerance
        self.isDefault = isDefault
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decodeIfPresent(GroupType.self, forKey: .type) ?? .select
        self.members = try c.decodeIfPresent([PolicyGroupMember].self, forKey: .members) ?? []
        self.testURL = try c.decodeIfPresent(String.self, forKey: .testURL)
        self.interval = try c.decodeIfPresent(String.self, forKey: .interval)
        self.tolerance = try c.decodeIfPresent(Int.self, forKey: .tolerance)
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    /// The conventional default group ("proxy") containing all nodes plus
    /// "direct". Created lazily by the engine when no groups are configured so
    /// that existing single-selector behavior is preserved.
    public static let defaultGroupName = "proxy"
}
