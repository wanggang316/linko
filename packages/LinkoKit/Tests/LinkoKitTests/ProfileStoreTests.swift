import XCTest
@testable import LinkoKit

/// Covers the pure profile list-management logic and the on-disk persistence +
/// migration. The single-config era must fold into one "默认" profile losslessly.
final class ProfileStoreTests: XCTestCase {

    // MARK: - Migration

    func testMigrateFoldsLegacyStateIntoDefaultProfile() {
        let prefs = AppPreferences(mixedPort: 7001, clashAPIPort: 9001, proxyMode: .tun)
        let subs = [Subscription(name: "Sub", url: URL(string: "https://e.com")!,
                                 nodes: [node("A")])]
        let collection = ProfileStore.migrate(legacyPreferences: prefs, legacySubscriptions: subs)

        XCTAssertEqual(collection.profiles.count, 1)
        let profile = collection.active
        XCTAssertEqual(profile.name, Profile.defaultProfileName)
        XCTAssertEqual(profile.preferences.mixedPort, 7001)
        XCTAssertEqual(profile.preferences.proxyMode, .tun)
        XCTAssertEqual(profile.subscriptions, subs)
        XCTAssertEqual(collection.activeProfileID, profile.id)
    }

    func testMigrateWithNoLegacyDataYieldsEmptyDefault() {
        let collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        XCTAssertEqual(collection.profiles.count, 1)
        XCTAssertEqual(collection.active.name, Profile.defaultProfileName)
        XCTAssertTrue(collection.active.subscriptions.isEmpty)
    }

    // MARK: - Normalization invariants

    func testNormalizedSynthesizesProfileWhenEmpty() {
        let collection = ProfileStore.normalized(profiles: [], activeProfileID: nil)
        XCTAssertEqual(collection.profiles.count, 1)
        XCTAssertEqual(collection.activeProfileID, collection.profiles[0].id)
    }

    func testNormalizedRepairsDanglingActiveID() {
        let p = Profile(name: "A")
        let collection = ProfileStore.normalized(profiles: [p], activeProfileID: UUID())
        XCTAssertEqual(collection.activeProfileID, p.id)
    }

    // MARK: - Create / duplicate / rename / delete / activate

    func testCreateAppendsAndActivates() {
        let base = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        let (after, created) = ProfileStore.create(name: "工作", in: base)
        XCTAssertEqual(after.profiles.count, 2)
        XCTAssertEqual(after.activeProfileID, created.id)
        XCTAssertEqual(after.active.name, "工作")
    }

    func testCreateDeduplicatesName() {
        var collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        collection = ProfileStore.create(name: "X", in: collection).collection
        collection = ProfileStore.create(name: "X", in: collection).collection
        let names = collection.profiles.map(\.name)
        XCTAssertTrue(names.contains("X"))
        XCTAssertTrue(names.contains("X 2"))
    }

    func testDuplicateDeepCopiesNodesAndRepointsSelection() throws {
        let original = node("A")
        var prefs = AppPreferences()
        prefs.selectedNodeID = original.id
        let sub = Subscription(name: "S", url: URL(string: "https://e.com")!, nodes: [original])
        let profile = Profile(name: "源", subscriptions: [sub], preferences: prefs)
        let collection = ProfileCollection(profiles: [profile], activeProfileID: profile.id)

        let (after, copy) = try ProfileStore.duplicate(id: profile.id, in: collection)
        XCTAssertEqual(after.profiles.count, 2)
        XCTAssertEqual(after.activeProfileID, copy.id)

        // The copy's node has a fresh id, and the copied selection points at it.
        let copiedNode = try XCTUnwrap(copy.allNodes.first)
        XCTAssertNotEqual(copiedNode.id, original.id)
        XCTAssertEqual(copy.preferences.selectedNodeID, copiedNode.id)
        XCTAssertNotEqual(copy.preferences.selectedNodeID, original.id)
    }

    func testRenameChangesNameOnly() throws {
        let collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        let id = collection.activeProfileID
        let after = try ProfileStore.rename(id: id, to: "改名", in: collection)
        XCTAssertEqual(after.active.name, "改名")
        XCTAssertEqual(after.activeProfileID, id)
    }

    func testDeleteActiveMovesActivationToNeighbor() throws {
        var collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        let first = collection.activeProfileID
        let created = ProfileStore.create(name: "B", in: collection)
        collection = created.collection
        // Active is now "B"; delete it and expect activation back on the first.
        let after = try ProfileStore.delete(id: created.created.id, in: collection)
        XCTAssertEqual(after.profiles.count, 1)
        XCTAssertEqual(after.activeProfileID, first)
    }

    func testDeleteLastProfileThrows() {
        let collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        XCTAssertThrowsError(try ProfileStore.delete(id: collection.activeProfileID, in: collection)) {
            XCTAssertEqual($0 as? ProfileStoreError, .cannotDeleteLastProfile)
        }
    }

    func testActivateUnknownThrows() {
        let collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        XCTAssertThrowsError(try ProfileStore.activate(id: UUID(), in: collection))
    }

    // MARK: - Persistence round trip

    func testSaveLoadRoundTripAndMigrationOnFirstLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linko-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(supportDirectoryURL: dir)

        // First load with no profiles/ dir migrates legacy state.
        let prefs = AppPreferences(mixedPort: 7100)
        let subs = [Subscription(name: "S", url: URL(string: "https://e.com")!, nodes: [node("A")])]
        let migrated = store.load(legacyPreferences: prefs, legacySubscriptions: subs)
        try store.save(migrated)

        // A fresh store loads the same collection from disk (no legacy needed).
        let store2 = ProfileStore(supportDirectoryURL: dir)
        let reloaded = store2.load(legacyPreferences: nil, legacySubscriptions: [])
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.active.preferences.mixedPort, 7100)
        XCTAssertEqual(reloaded.active.subscriptions.first?.nodes.first?.name, "A")
        XCTAssertEqual(reloaded.activeProfileID, migrated.activeProfileID)
    }

    func testSavePrunesRemovedProfileFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linko-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(supportDirectoryURL: dir)

        var collection = store.load(legacyPreferences: nil, legacySubscriptions: [])
        let created = ProfileStore.create(name: "B", in: collection)
        collection = created.collection
        try store.save(collection)

        let afterDelete = try ProfileStore.delete(id: created.created.id, in: collection)
        try store.save(afterDelete)

        let removedFile = store.profilesDirectoryURL
            .appendingPathComponent("\(created.created.id.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedFile.path))
    }

    // MARK: - Migration losslessness

    func testMigratePreservesSelectionAndRoutingLosslessly() {
        let selected = node("Sel")
        var routing = RoutingConfig.empty
        routing.rules = [RoutingRule(type: .domainSuffix, value: "example.com", target: "PROXY")]
        var prefs = AppPreferences(clashAPIPort: 9123, proxyMode: .tun)
        prefs.selectedNodeID = selected.id
        prefs.routing = routing
        let sub = Subscription(name: "S", url: URL(string: "https://e.com")!, nodes: [selected])

        let collection = ProfileStore.migrate(legacyPreferences: prefs, legacySubscriptions: [sub])
        let active = collection.active
        XCTAssertEqual(active.preferences, prefs, "every preference field must survive migration")
        XCTAssertEqual(active.preferences.selectedNodeID, selected.id)
        XCTAssertEqual(active.preferences.routing.rules.first?.value, "example.com")
        XCTAssertEqual(active.allNodes.first?.id, selected.id)
    }

    // MARK: - upsert

    func testUpsertReplacesActiveProfileEdits() {
        var collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        var edited = collection.active
        edited.preferences.mixedPort = 7654
        edited.subscriptions = [Subscription(name: "New", url: URL(string: "https://e.com")!,
                                             nodes: [node("Z")])]
        collection = ProfileStore.upsert(edited, in: collection)
        XCTAssertEqual(collection.active.preferences.mixedPort, 7654)
        XCTAssertEqual(collection.active.subscriptions.first?.nodes.first?.name, "Z")
        XCTAssertEqual(collection.activeProfileID, edited.id, "active pointer is unchanged by upsert")
    }

    func testUpsertOfUnknownProfileIsNoOp() {
        let collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        let stranger = Profile(name: "外来")
        let after = ProfileStore.upsert(stranger, in: collection)
        XCTAssertEqual(after.profiles.map(\.id), collection.profiles.map(\.id))
    }

    // MARK: - uniqueName

    func testUniqueNameAppendsCounter() {
        var collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        collection = ProfileStore.create(name: "工作", in: collection).collection
        XCTAssertEqual(ProfileStore.uniqueName("工作", in: collection), "工作 2")
        XCTAssertEqual(ProfileStore.uniqueName("家庭", in: collection), "家庭")
    }

    func testUniqueNameBlankFallsBackToDefaultName() {
        let collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        // The migrated default already owns "默认", so a blank request dedupes.
        XCTAssertEqual(ProfileStore.uniqueName("   ", in: collection), "\(Profile.defaultProfileName) 2")
    }

    // MARK: - activate semantics

    func testActivateTouchesUpdatedAtAndSetsActive() throws {
        var collection = ProfileStore.migrate(legacyPreferences: nil, legacySubscriptions: [])
        let created = ProfileStore.create(name: "B", in: collection)
        collection = created.collection // active == B
        let first = collection.profiles[0]
        let past = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Force a known-old updatedAt on the first profile so the touch is visible.
        var seeded = collection
        seeded.profiles[0].updatedAt = past
        let after = try ProfileStore.activate(id: first.id, in: seeded, now: now)
        XCTAssertEqual(after.activeProfileID, first.id)
        XCTAssertEqual(after.active.updatedAt, now)
    }

    // MARK: - Decoder repair

    func testCollectionDecoderRepairsDanglingActiveID() throws {
        let profile = Profile(name: "A")
        let json = """
        {"profiles":[\(profileJSON(profile))],"activeProfileID":"\(UUID().uuidString)"}
        """
        let decoded = try makeDecoder().decode(ProfileCollection.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.activeProfileID, profile.id, "dangling active id repairs to first profile")
    }

    func testLoadWithCorruptIndexIsNormalized() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linko-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(supportDirectoryURL: dir)
        let collection = store.load(legacyPreferences: AppPreferences(mixedPort: 7000),
                                    legacySubscriptions: [])
        try store.save(collection)

        // Corrupt the index file; the store must fall back to migration-on-load
        // (the profiles/ dir exists but the index is unreadable → no profiles
        // load → normalized synthesizes a fresh default).
        let indexURL = store.profilesDirectoryURL.appendingPathComponent(ProfileStore.indexFileName)
        try Data("not json".utf8).write(to: indexURL)

        let reloaded = store.load(legacyPreferences: nil, legacySubscriptions: [])
        XCTAssertFalse(reloaded.profiles.isEmpty)
        XCTAssertEqual(reloaded.activeProfileID, reloaded.profiles[0].id)
    }

    // MARK: - Helpers

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func profileJSON(_ profile: Profile) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(profile)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Fixtures

    private func node(_ name: String) -> ProxyNode {
        ProxyNode(name: name, protocolType: .shadowsocks, server: "\(name).example.com",
                  port: 8388, password: "pw", method: "aes-256-gcm")
    }
}
