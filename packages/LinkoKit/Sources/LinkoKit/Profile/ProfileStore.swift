import Foundation

/// The persisted set of profiles plus a pointer to the active one. This is the
/// value the app holds in memory and `ProfileStore` reads/writes as a whole.
///
/// Invariant maintained by `ProfileStore`: `profiles` is never empty (there is
/// always at least the "默认" profile) and `activeProfileID` always names an
/// element of `profiles`. The tolerant decoder + `normalized()` repair any
/// persisted state that violates these.
public struct ProfileCollection: Codable, Hashable, Sendable {
    public var profiles: [Profile]
    public var activeProfileID: UUID

    public init(profiles: [Profile], activeProfileID: UUID) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        let active = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        let repaired = ProfileStore.normalized(profiles: decoded, activeProfileID: active)
        self.profiles = repaired.profiles
        self.activeProfileID = repaired.activeProfileID
    }

    /// The active profile (always resolvable thanks to the invariant).
    public var active: Profile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
    }
}

/// Errors a `ProfileStore` mutation can surface.
public enum ProfileStoreError: Error, Equatable, LocalizedError {
    /// Attempted to delete the only remaining profile; at least one must exist.
    case cannotDeleteLastProfile
    /// Referenced a profile id that is not in the collection.
    case profileNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .cannotDeleteLastProfile:
            return "至少需要保留一个配置档案，无法删除最后一个。"
        case let .profileNotFound(id):
            return "未找到配置档案（\(id.uuidString)）。"
        }
    }
}

/// Owns the on-disk multi-profile layout and the pure list-management logic the
/// app's `AppState` drives. Profiles persist as one JSON file per profile under
/// `<support>/profiles/<id>.json`, plus an `index.json` recording profile order
/// and the active id. Loading migrates a pre-multi-profile `preferences.json` +
/// `subscriptions.json` into a single "默认" profile without data loss.
///
/// The list-management helpers (`create`/`duplicate`/`rename`/`delete`/`activate`
/// /`normalized`/`migrate`) are pure and side-effect-free so they unit-test
/// offline; the instance methods add atomic file I/O around them.
public struct ProfileStore {
    /// Subdirectory under the support directory holding per-profile JSON files.
    public static let directoryName = "profiles"
    /// Index filename recording order + the active profile id.
    public static let indexFileName = "index.json"

    private let directoryURL: URL

    /// - Parameter supportDirectoryURL: the app's
    ///   `~/Library/Application Support/linko` directory. Profiles live under
    ///   `<supportDirectoryURL>/profiles/`.
    public init(supportDirectoryURL: URL) {
        self.directoryURL = supportDirectoryURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// The `profiles/` directory URL (exposed for tests / diagnostics).
    public var profilesDirectoryURL: URL { directoryURL }

    // MARK: - Pure list management (offline-testable)

    /// Repairs a decoded `(profiles, activeProfileID)` pair to satisfy the
    /// store invariants: a non-empty list (synthesizing an empty "默认" profile
    /// when none exist) and an `activeProfileID` that names an element (falling
    /// back to the first profile). Order is otherwise preserved.
    public static func normalized(
        profiles: [Profile],
        activeProfileID: UUID?
    ) -> ProfileCollection {
        var list = profiles
        if list.isEmpty {
            list = [Profile(name: Profile.defaultProfileName)]
        }
        let active = activeProfileID.flatMap { id in list.contains(where: { $0.id == id }) ? id : nil }
            ?? list[0].id
        return ProfileCollection(profiles: list, activeProfileID: active)
    }

    /// Builds the initial collection for a fresh or migrating install. When a
    /// legacy single-config setup is detected (`legacyPreferences`/
    /// `legacySubscriptions`, loaded from the old `preferences.json`/
    /// `subscriptions.json`), it is folded losslessly into one active "默认"
    /// profile. With no legacy data, an empty "默认" profile is returned.
    public static func migrate(
        legacyPreferences: AppPreferences?,
        legacySubscriptions: [Subscription],
        now: Date = Date()
    ) -> ProfileCollection {
        let profile = Profile(
            name: Profile.defaultProfileName,
            subscriptions: legacySubscriptions,
            preferences: legacyPreferences ?? .default,
            createdAt: now,
            updatedAt: now
        )
        return ProfileCollection(profiles: [profile], activeProfileID: profile.id)
    }

    /// Appends a new, empty profile and makes it active. Returns the updated
    /// collection and the new profile's id.
    public static func create(
        name: String,
        in collection: ProfileCollection,
        now: Date = Date()
    ) -> (collection: ProfileCollection, created: Profile) {
        let profile = Profile(name: uniqueName(name, in: collection), createdAt: now, updatedAt: now)
        var profiles = collection.profiles
        profiles.append(profile)
        return (ProfileCollection(profiles: profiles, activeProfileID: profile.id), profile)
    }

    /// Deep-duplicates the profile with `id` (fresh node ids, re-pointed
    /// selection) under a derived unique name, inserts it after the original,
    /// and makes the copy active. Throws `.profileNotFound` if `id` is unknown.
    public static func duplicate(
        id: UUID,
        in collection: ProfileCollection,
        now: Date = Date()
    ) throws -> (collection: ProfileCollection, created: Profile) {
        guard let index = collection.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        let source = collection.profiles[index]
        let copy = source.duplicated(named: uniqueName("\(source.name) 副本", in: collection), now: now)
        var profiles = collection.profiles
        profiles.insert(copy, at: index + 1)
        return (ProfileCollection(profiles: profiles, activeProfileID: copy.id), copy)
    }

    /// Renames the profile with `id`. Throws `.profileNotFound` if unknown. The
    /// requested name is used as-is (duplicates are allowed; the UI may call
    /// `uniqueName` first if it wants distinctness).
    public static func rename(
        id: UUID,
        to newName: String,
        in collection: ProfileCollection,
        now: Date = Date()
    ) throws -> ProfileCollection {
        guard let index = collection.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        var profiles = collection.profiles
        profiles[index].name = newName
        profiles[index].updatedAt = now
        return ProfileCollection(profiles: profiles, activeProfileID: collection.activeProfileID)
    }

    /// Removes the profile with `id`. Throws `.cannotDeleteLastProfile` when it
    /// is the only one, or `.profileNotFound` if unknown. When the active
    /// profile is removed, activation moves to the neighbor (previous, else
    /// next) so there is always an active profile.
    public static func delete(
        id: UUID,
        in collection: ProfileCollection
    ) throws -> ProfileCollection {
        guard collection.profiles.contains(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        guard collection.profiles.count > 1 else {
            throw ProfileStoreError.cannotDeleteLastProfile
        }
        guard let index = collection.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        var profiles = collection.profiles
        profiles.remove(at: index)
        var active = collection.activeProfileID
        if active == id {
            // Prefer the previous neighbor, else the new element at `index`.
            let neighborIndex = max(0, index - 1)
            active = profiles[neighborIndex].id
        }
        return ProfileCollection(profiles: profiles, activeProfileID: active)
    }

    /// Makes the profile with `id` active. Throws `.profileNotFound` if unknown.
    /// Touches its `updatedAt` so "recently used" ordering reflects the switch.
    public static func activate(
        id: UUID,
        in collection: ProfileCollection,
        now: Date = Date()
    ) throws -> ProfileCollection {
        guard let index = collection.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        var profiles = collection.profiles
        profiles[index].updatedAt = now
        return ProfileCollection(profiles: profiles, activeProfileID: id)
    }

    /// Replaces the stored copy of `profile` in `collection` (matched by id),
    /// used to persist edits the active profile accumulates (imports, selection
    /// changes, routing edits). No-op if the id is absent.
    public static func upsert(
        _ profile: Profile,
        in collection: ProfileCollection,
        now: Date = Date()
    ) -> ProfileCollection {
        guard let index = collection.profiles.firstIndex(where: { $0.id == profile.id }) else {
            return collection
        }
        var profiles = collection.profiles
        var updated = profile
        updated.updatedAt = now
        profiles[index] = updated
        return ProfileCollection(profiles: profiles, activeProfileID: collection.activeProfileID)
    }

    /// Returns `name` if it is not already used by another profile, otherwise
    /// appends ` 2`, ` 3`, … until unique. Comparison is on the trimmed string.
    public static func uniqueName(_ name: String, in collection: ProfileCollection) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Profile.defaultProfileName
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Set(collection.profiles.map(\.name))
        guard existing.contains(base) else { return base }
        var counter = 2
        while existing.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    // MARK: - Persistence (atomic file I/O)

    /// Loads the full collection from disk. When `profiles/` does not yet exist,
    /// migrates the supplied legacy single-config values into one "默认" profile
    /// and returns it (the caller persists afterwards). A present-but-corrupt
    /// index is normalized rather than thrown.
    public func load(
        legacyPreferences: AppPreferences?,
        legacySubscriptions: [Subscription]
    ) -> ProfileCollection {
        guard let index = readIndex() else {
            return Self.migrate(
                legacyPreferences: legacyPreferences,
                legacySubscriptions: legacySubscriptions
            )
        }
        var loaded: [Profile] = []
        for id in index.order {
            if let profile = readProfile(id: id) {
                loaded.append(profile)
            }
        }
        return Self.normalized(profiles: loaded, activeProfileID: index.activeProfileID)
    }

    /// Writes every profile file and the index atomically, pruning any stale
    /// per-profile files no longer referenced by the collection.
    public func save(_ collection: ProfileCollection) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = Self.makeEncoder()
        for profile in collection.profiles {
            let data = try encoder.encode(profile)
            try data.write(to: profileURL(id: profile.id), options: .atomic)
        }
        let index = ProfileIndex(
            order: collection.profiles.map(\.id),
            activeProfileID: collection.activeProfileID
        )
        let indexData = try encoder.encode(index)
        try indexData.write(to: indexURL, options: .atomic)
        pruneOrphans(keeping: Set(collection.profiles.map(\.id)))
    }

    // MARK: - On-disk index

    /// The `index.json` payload: profile order + the active id. Profile bodies
    /// live in their own files so a large profile rewrite doesn't churn others.
    public struct ProfileIndex: Codable, Hashable, Sendable {
        public var order: [UUID]
        public var activeProfileID: UUID

        public init(order: [UUID], activeProfileID: UUID) {
            self.order = order
            self.activeProfileID = activeProfileID
        }
    }

    private var indexURL: URL { directoryURL.appendingPathComponent(Self.indexFileName) }

    private func profileURL(id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func readIndex() -> ProfileIndex? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? Self.makeDecoder().decode(ProfileIndex.self, from: data)
    }

    private func readProfile(id: UUID) -> Profile? {
        guard let data = try? Data(contentsOf: profileURL(id: id)) else { return nil }
        return try? Self.makeDecoder().decode(Profile.self, from: data)
    }

    private func pruneOrphans(keeping ids: Set<UUID>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.pathExtension == "json" && url.lastPathComponent != Self.indexFileName {
            let stem = url.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: stem), !ids.contains(id) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
