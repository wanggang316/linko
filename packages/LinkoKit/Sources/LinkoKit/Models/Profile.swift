import Foundation

/// A named, self-contained configuration bundle (a "Surge profile"): the set of
/// imported subscriptions plus the `AppPreferences` that select a node, routing
/// layer, proxy mode, and ports. Switching the active profile re-generates the
/// sing-box config from that profile's `preferences` + `subscriptions`, then
/// validates and (if running) restarts the core.
///
/// `preferences` reuses the existing tolerant `AppPreferences` value verbatim so
/// every routing/DNS/port/mode setting and its backward-compatible decoder are
/// inherited for free — the single-config era's `preferences.json` becomes one
/// profile's `preferences`, losslessly, during migration.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    /// Stable identity, also the on-disk filename stem
    /// (`profiles/<id>.json`). Preserved across renames.
    public var id: UUID
    /// User-facing display name (Chinese by default). Need not be unique, but
    /// the store offers `uniqueName(...)` helpers to keep duplicates legible.
    public var name: String
    /// This profile's node subscriptions and their last-parsed nodes.
    public var subscriptions: [Subscription]
    /// This profile's selection/routing/mode/port settings.
    public var preferences: AppPreferences
    /// Creation timestamp; used for stable ordering and as a migration marker.
    public var createdAt: Date
    /// Last time this profile was switched to / saved; drives "recently used"
    /// ordering in the UI.
    public var updatedAt: Date

    /// The conventional name of the profile the single-config setup migrates
    /// into on first run.
    public static let defaultProfileName = "默认"

    public init(
        id: UUID = UUID(),
        name: String,
        subscriptions: [Subscription] = [],
        preferences: AppPreferences = .default,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subscriptions = subscriptions
        self.preferences = preferences
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.defaultProfileName
        self.subscriptions = try c.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        self.preferences = try c.decodeIfPresent(AppPreferences.self, forKey: .preferences) ?? .default
        let now = Date()
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? now
    }

    /// All nodes across this profile's subscriptions, in subscription order —
    /// the candidate set for `preferences.selectedNodeID`.
    public var allNodes: [ProxyNode] {
        subscriptions.flatMap(\.nodes)
    }

    /// Returns a deep copy under a new identity and name, with timestamps reset
    /// to `now` and every subscription/node re-keyed to a fresh `UUID` so the
    /// duplicate is fully independent (no shared node ids that would alias the
    /// original's selection). `selectedNodeID` is re-pointed at the copied node
    /// that corresponds to the original selection, or `nil` if none.
    public func duplicated(named newName: String, now: Date = Date()) -> Profile {
        var idMap: [UUID: UUID] = [:]
        let copiedSubscriptions: [Subscription] = subscriptions.map { sub in
            var copy = sub
            copy.id = UUID()
            copy.nodes = sub.nodes.map { node in
                var n = node
                let freshID = UUID()
                idMap[node.id] = freshID
                n.id = freshID
                return n
            }
            return copy
        }
        var copiedPreferences = preferences
        if let oldSelection = preferences.selectedNodeID {
            copiedPreferences.selectedNodeID = idMap[oldSelection]
        }
        return Profile(
            id: UUID(),
            name: newName,
            subscriptions: copiedSubscriptions,
            preferences: copiedPreferences,
            createdAt: now,
            updatedAt: now
        )
    }
}
