import Combine
import LinkoKit
import NetworkExtension
import XCTest

/// Unit tests for the quick-add ↔ global-state integration: the capture
/// reset state machine behind (re)triggering the window (VAL-QUICKADD-010,
/// VAL-CAPTURE-011), save visibility to every preferences-derived surface
/// (VAL-QUICKADD-018), survival of a concurrent editor draft
/// (VAL-QUICKADD-019), equivalent-rule coexistence across window sessions
/// (VAL-QUICKADD-014), and saving onto a target deleted mid-session
/// (VAL-QUICKADD-013).
///
/// The app sources compile directly into this bundle (no app host), so every
/// system effect stays behind the injected `AppDependencies` protocols and
/// the capture read is a stubbed closure — no osascript, no TCC.
@MainActor
final class AppStateQuickAddTests: XCTestCase {

    // MARK: - Capture reset state machine

    /// A trigger on an idle state resets the published capture to
    /// `.capturing` synchronously — the transition `QuickAddRuleView`
    /// observes to drop any previous form — then lands the fresh outcome.
    func testTriggerResetsToCapturingThenLandsTheFreshOutcome() async throws {
        let state = try makeState()
        XCTAssertEqual(state.quickAddCapture, .manual(nil))

        state.beginQuickAddCapture { .captured(urlString: "https://www.example.com/") }

        XCTAssertEqual(state.quickAddCapture, .capturing)
        await waitUntil { state.quickAddCapture == .captured(urlString: "https://www.example.com/") }
    }

    /// Re-triggering after a capture settled — the window may still be open,
    /// holding unsaved edits — must restart from `.capturing` and land the
    /// *new* outcome, including the degradation to manual mode when the new
    /// trigger finds no source (VAL-QUICKADD-010, VAL-CAPTURE-011).
    func testReTriggerAfterSettledCaptureResetsAndRecaptures() async throws {
        let state = try makeState()
        state.beginQuickAddCapture { .captured(urlString: "https://old.example.com/") }
        await waitUntil { state.quickAddCapture == .captured(urlString: "https://old.example.com/") }

        state.beginQuickAddCapture { .manual(nil) }

        // The stale capture is gone before the new one lands: the form
        // rebuild is driven off this reset, so no draft can survive it.
        XCTAssertEqual(state.quickAddCapture, .capturing)
        await waitUntil { state.quickAddCapture == .manual(nil) }
    }

    /// A trigger landing while a capture is in flight must not start a second
    /// read (the reader is single-flight per browser); the in-flight result
    /// still lands, and the machine accepts a fresh trigger afterwards.
    func testReTriggerWhileCaptureInFlightStartsNoSecondRead() async throws {
        let state = try makeState()
        let gate = Gate()
        let secondReads = Counter()

        state.beginQuickAddCapture {
            await gate.wait()
            return .captured(urlString: "https://first.example.com/")
        }
        XCTAssertEqual(state.quickAddCapture, .capturing)

        state.beginQuickAddCapture {
            await secondReads.increment()
            return .manual(nil)
        }

        await gate.release()
        await waitUntil { state.quickAddCapture == .captured(urlString: "https://first.example.com/") }
        let reads = await secondReads.count
        XCTAssertEqual(reads, 0)

        // The settled machine is idle again: the next trigger re-captures.
        state.beginQuickAddCapture { .manual(nil) }
        XCTAssertEqual(state.quickAddCapture, .capturing)
        await waitUntil { state.quickAddCapture == .manual(nil) }
    }

    // MARK: - Window close clears the capture

    /// Closing the window after a capture settled — save, cancel, or the
    /// close control — must drop the captured URL: the published state
    /// returns to the manual baseline, so the full page URL never lingers in
    /// memory behind a closed window.
    func testClearAfterSettledCaptureDropsTheCapturedURL() async throws {
        let state = try makeState()
        state.beginQuickAddCapture { .captured(urlString: "https://private.example.com/path") }
        await waitUntil { state.quickAddCapture == .captured(urlString: "https://private.example.com/path") }

        state.clearQuickAddCapture()

        XCTAssertEqual(state.quickAddCapture, .manual(nil))
    }

    /// Closing the window while a capture is still in flight must not
    /// interrupt the landing: the clear is a no-op (the in-flight task owns
    /// the state), the outcome still lands, and only a clear on the settled
    /// machine takes effect.
    func testClearWhileCaptureInFlightLeavesTheLandingAlone() async throws {
        let state = try makeState()
        let gate = Gate()
        state.beginQuickAddCapture {
            await gate.wait()
            return .captured(urlString: "https://inflight.example.com/")
        }
        XCTAssertEqual(state.quickAddCapture, .capturing)

        state.clearQuickAddCapture()
        XCTAssertEqual(state.quickAddCapture, .capturing)

        await gate.release()
        await waitUntil { state.quickAddCapture == .captured(urlString: "https://inflight.example.com/") }

        state.clearQuickAddCapture()
        XCTAssertEqual(state.quickAddCapture, .manual(nil))
    }

    // MARK: - Save visibility (Dashboard rules page derives from preferences)

    /// A quick-add save is a plain `updatePreferences` prepend: the published
    /// `preferences` — the single source every rules surface derives from on
    /// render — carries the new first row as soon as the call returns, with
    /// no refresh step (VAL-QUICKADD-018).
    func testQuickAddSaveIsImmediatelyVisibleInPublishedPreferences() async throws {
        let state = try makeState()
        var form = QuickAddFormModel(
            capturedInput: "https://www.example.com/", defaultTarget: "proxy"
        )
        let rule = try XCTUnwrap(form.commitRule())

        var prefs = state.preferences
        prefs.routing.rules.insert(rule, at: 0)
        await state.updatePreferences(prefs)

        XCTAssertEqual(state.preferences.routing.rules.first, rule)
        XCTAssertNil(state.lastErrorMessage)
    }

    /// An editor sheet holding an uncommitted draft must not lose a rule the
    /// quick-add window saved in the meantime: `RulesView.apply` re-reads the
    /// live routing at commit time, so the sequential state-layer semantics
    /// are prepend-then-append with a re-read in between — both rules land
    /// (VAL-QUICKADD-019).
    func testQuickAddSaveAndConcurrentSheetDraftBothSurvive() async throws {
        let state = try makeState()
        let existing = RoutingRule(type: .domainSuffix, value: "old.example.com", target: "direct")
        var prefs = state.preferences
        prefs.routing.rules = [existing]
        await state.updatePreferences(prefs)

        // The quick-add window saves first (while the sheet draft is open).
        var form = QuickAddFormModel(
            capturedInput: "https://quick.example.com/", defaultTarget: "proxy"
        )
        let quickRule = try XCTUnwrap(form.commitRule())
        var quickPrefs = state.preferences
        quickPrefs.routing.rules.insert(quickRule, at: 0)
        await state.updatePreferences(quickPrefs)

        // The sheet commits afterwards, building from a fresh read of the
        // live preferences — never from the routing it captured on open.
        let sheetRule = RoutingRule(type: .domain, value: "sheet.example.com", target: "proxy")
        var sheetPrefs = state.preferences
        sheetPrefs.routing.rules.append(sheetRule)
        await state.updatePreferences(sheetPrefs)

        XCTAssertEqual(state.preferences.routing.rules, [quickRule, existing, sheetRule])
        XCTAssertNil(state.lastErrorMessage)
    }

    /// The save paths (quick-add window and rules page) snapshot
    /// `preferences` *inside* their `Task` — in the same main-actor turn as
    /// `updatePreferences`, which reads and writes `preferences` with no
    /// suspension in between. Two saves whose tasks were enqueued in the same
    /// turn, before either update ran, therefore never build on the same
    /// stale snapshot: the later task reads a state already carrying the
    /// earlier rule, and both survive.
    func testSnapshotInsideTheTaskNeverLosesAConcurrentSave() async throws {
        let state = try makeState()
        let first = RoutingRule(type: .domainSuffix, value: "first.example.com", target: "proxy")
        let second = RoutingRule(type: .domainSuffix, value: "second.example.com", target: "proxy")

        // Mirror the view-side pattern: both tasks created back-to-back in
        // one turn, each deferring its snapshot into the task body.
        let firstSave = Task {
            var preferences = state.preferences
            preferences.routing.rules.insert(first, at: 0)
            await state.updatePreferences(preferences)
        }
        let secondSave = Task {
            var preferences = state.preferences
            preferences.routing.rules.insert(second, at: 0)
            await state.updatePreferences(preferences)
        }
        await firstSave.value
        await secondSave.value

        XCTAssertEqual(state.preferences.routing.rules, [second, first])
        XCTAssertNil(state.lastErrorMessage)
    }

    // MARK: - Duplicate coexistence across window sessions

    /// Two independent window sessions saving the same page produce two
    /// coexisting, equivalent rules with distinct identities — no dedup, no
    /// error — and both survive a relaunch from disk (VAL-QUICKADD-014).
    func testEquivalentRulesFromTwoWindowSessionsCoexist() async throws {
        let supportDirectory = try makeSupportDirectory()
        let state = try makeState(supportDirectory: supportDirectory)

        // Each window session rebuilds its own form model from the capture.
        var firstSession = QuickAddFormModel(
            capturedInput: "https://www.example.com/", defaultTarget: "proxy"
        )
        var secondSession = QuickAddFormModel(
            capturedInput: "https://www.example.com/", defaultTarget: "proxy"
        )
        let first = try XCTUnwrap(firstSession.commitRule())
        let second = try XCTUnwrap(secondSession.commitRule())

        var prefs = state.preferences
        prefs.routing.rules.insert(first, at: 0)
        await state.updatePreferences(prefs)
        prefs = state.preferences
        prefs.routing.rules.insert(second, at: 0)
        await state.updatePreferences(prefs)

        XCTAssertEqual(state.preferences.routing.rules, [second, first])
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.type, second.type)
        XCTAssertEqual(first.value, second.value)
        XCTAssertEqual(first.target, second.target)
        XCTAssertNil(state.lastErrorMessage)

        // Both rows come back from the profile store on the next launch.
        let relaunched = AppState(
            dependencies: makeDependencies(), supportDirectoryURL: supportDirectory
        )
        XCTAssertEqual(relaunched.preferences.routing.rules, [second, first])
    }

    // MARK: - Target deleted while the window is open

    /// Deleting the chosen policy group while the quick-add window is open
    /// must not block the save: the rule lands with its tag verbatim, and the
    /// live target catalogue reports it unresolved — which is exactly what
    /// drives the rule row's「未知出站目标」warning. The config builder side
    /// (unresolved targets skipped at generation) is pinned by LinkoKit's
    /// SingBoxRoutingBuilderTests (VAL-QUICKADD-013).
    func testSaveOntoADeletedTargetKeepsTheRuleAndFlagsItUnresolved() async throws {
        let state = try makeState()
        var withGroup = state.preferences
        withGroup.routing.groups.append(PolicyGroup(name: "工作"))
        await state.updatePreferences(withGroup)

        // The window opened while the group existed and selected it…
        var form = QuickAddFormModel(
            capturedInput: "https://www.example.com/", defaultTarget: "proxy"
        )
        form.targetTag = "工作"

        // …then the group is deleted from the policy-groups page.
        var withoutGroup = state.preferences
        withoutGroup.routing.groups.removeAll { $0.name == "工作" }
        await state.updatePreferences(withoutGroup)

        XCTAssertNil(form.validationProblem)
        let rule = try XCTUnwrap(form.commitRule())
        var saved = state.preferences
        saved.routing.rules.insert(rule, at: 0)
        await state.updatePreferences(saved)

        XCTAssertEqual(state.preferences.routing.rules.first, rule)
        XCTAssertEqual(rule.target, "工作")
        let targets = RoutingTargets(routing: state.preferences.routing, nodes: [], nodeTags: [])
        XCTAssertFalse(targets.isResolved(rule.target))
        XCTAssertEqual(targets.resolve(rule.target).displayName, "工作")
    }

    // MARK: - Fixture

    /// Builds an `AppState` on inert mocks with a per-test support directory.
    /// The proxy stays off throughout, so `updatePreferences` persists without
    /// ever touching a core.
    private func makeState(supportDirectory: URL? = nil) throws -> AppState {
        AppState(
            dependencies: makeDependencies(),
            supportDirectoryURL: try supportDirectory ?? makeSupportDirectory()
        )
    }

    private func makeDependencies() -> AppDependencies {
        AppDependencies(
            coreRunner: CoreRunnerStub(),
            systemProxy: SystemProxyStub(),
            configBuilder: ConfigBuilderStub(),
            subscriptionParser: SubscriptionParserStub(),
            configValidator: ConfigValidatorStub(),
            loginItem: LoginItemStub(),
            makeClashAPI: { _ in ClashAPIStub() },
            tunnelController: TunnelControllerStub()
        )
    }

    /// A fresh per-test support directory, removed on teardown.
    private func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linko-quickadd-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Polls `condition` on the main actor until it holds or `timeout`
    /// passes, then asserts it — the capture task needs the main actor free
    /// to land its result.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for the capture state")
    }
}

// MARK: - Async test plumbing

/// Suspends readers until released, so a test can hold a capture in flight.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// A data-race-free invocation counter for `@Sendable` read closures.
private actor Counter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

// MARK: - Inert dependency stubs

private final class CoreRunnerStub: CoreRunning {
    var state: CoreState = .stopped
    var isRunning: Bool { false }
    var onStateChange: (@Sendable (CoreState) -> Void)?

    func start(binaryURL: URL, configFileURL: URL, logFileURL: URL) throws {}
    func stop() {}
}

private final class SystemProxyStub: SystemProxyRunning {
    var isEnabled: Bool { false }

    func enable(host: String, port: Int) throws {}
    func disable() throws {}
    func restorePersistedSnapshotIfPresent() throws -> Bool { false }
}

private final class ConfigBuilderStub: SingBoxConfigBuilding {
    func build(nodes: [ProxyNode], preferences: AppPreferences) throws -> Data {
        Data("{}".utf8)
    }

    func outboundTags(for nodes: [ProxyNode]) -> [String] {
        nodes.map(\.name)
    }

    func validate(nodes: [ProxyNode], routing: RoutingConfig) throws -> [String] {
        []
    }
}

private struct SubscriptionParserStub: SubscriptionParsing {
    func parse(clashYAML: String) throws -> SubscriptionParseResult {
        SubscriptionParseResult(nodes: [])
    }

    func parse(subscription content: String) throws -> SubscriptionParseResult {
        SubscriptionParseResult(nodes: [])
    }
}

private final class ConfigValidatorStub: ConfigValidating, @unchecked Sendable {
    func validate(configFileURL: URL, binaryURL: URL) -> ConfigValidationResult {
        ConfigValidationResult(isValid: true, errors: [], warnings: [])
    }
}

private struct LoginItemStub: LoginItemControlling {
    var status: LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private final class TunnelControllerStub: TunnelControlling {
    private let statusSubject = CurrentValueSubject<NEVPNStatus, Never>(.invalid)
    var status: NEVPNStatus { statusSubject.value }
    var statusPublisher: AnyPublisher<NEVPNStatus, Never> { statusSubject.eraseToAnyPublisher() }
    var isActive: Bool { false }

    func load() async {}
    func start(configJSON: String) async throws {}
    func stop() {}
    func reload(configJSON: String) async throws {}
}

private struct ClashAPIStub: ClashAPIProviding {
    struct Unused: Error {}

    func version() async throws -> String { "stub" }
    func proxies() async throws -> [String: ClashProxy] { [:] }
    func select(selector: String, nodeName: String) async throws {}
    func delay(nodeName: String, testURL: String, timeoutMilliseconds: Int) async throws -> Int { 0 }
    func connectionsSnapshot() async throws -> ClashConnectionsSnapshot { throw Unused() }
    func connectionsStream() -> AsyncThrowingStream<ClashConnectionsSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func trafficStream() -> AsyncThrowingStream<ClashTrafficTick, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func logsStream(level: ClashLogLevel) -> AsyncThrowingStream<ClashLogEntry, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func closeConnection(id: String?) async throws {}
}
