import Combine
import LinkoKit
import NetworkExtension
import XCTest

/// Unit tests for `AppState`'s TUN hot-reload failure handling (VAL-RELOAD-015).
///
/// The app sources are compiled directly into this bundle (no app host), so
/// every system effect stays behind the injected `AppDependencies` protocols:
/// the tunnel is a recording mock, the config builder/validator/Clash API are
/// inert stand-ins, and the support directory is a per-test temp folder.
@MainActor
final class AppStateTunReloadTests: XCTestCase {

    /// A live-tunnel reload that fails must fall back to a full restart —
    /// stop, then start carrying the freshly built config — so the user is
    /// never left on a stale config (VAL-RELOAD-015).
    func testReloadFailureFallsBackToStopThenStartOnNewConfig() async throws {
        let fixture = try await makeTunReadyFixture()
        fixture.tunnel.reloadError = AppError(message: "reload rejected")

        var edited = fixture.node
        edited.server = "updated.example.com"
        await fixture.state.updateManualNode(edited)

        XCTAssertEqual(fixture.tunnel.calls, [.reload, .stop, .start])
        // Both the rejected reload and the fallback start carry the config
        // built from the *edited* node — the tunnel lands on the new config.
        XCTAssertTrue(fixture.tunnel.reloadedConfigs.last?.contains("updated.example.com") ?? false)
        XCTAssertTrue(fixture.tunnel.startedConfigs.last?.contains("updated.example.com") ?? false)
        XCTAssertEqual(fixture.state.coreState, .running(pid: 0))
        XCTAssertNil(fixture.state.lastErrorMessage)
    }

    /// A TUN config build failure during reconfigure must surface
    /// `lastErrorMessage` and leave the running tunnel untouched — the
    /// silent-drop gap fixed by routing-reload-on-save must not regress.
    func testTunConfigBuildFailureSurfacesErrorAndLeavesTunnelUntouched() async throws {
        let fixture = try await makeTunReadyFixture()
        fixture.builder.buildError = AppError(message: "build exploded")

        var edited = fixture.node
        edited.server = "updated.example.com"
        await fixture.state.updateManualNode(edited)

        XCTAssertEqual(fixture.tunnel.calls, [])
        XCTAssertEqual(
            fixture.state.lastErrorMessage,
            "生成 TUN 配置失败，隧道仍在运行旧配置：build exploded"
        )
    }

    /// A burst of routing edits through `updatePreferences` coalesces into a
    /// single debounced tunnel reload (no stop/start churn).
    func testBurstRoutingEditsCoalesceIntoASingleReload() async throws {
        let fixture = try await makeTunReadyFixture()

        var prefs = fixture.state.preferences
        prefs.routing.finalTarget = "direct"
        await fixture.state.updatePreferences(prefs)
        prefs.routing.finalTarget = "block"
        await fixture.state.updatePreferences(prefs)

        // Nothing fires inside the quiet window; the reload is pending.
        XCTAssertEqual(fixture.tunnel.calls, [])

        await waitUntil(timeout: 5) { !fixture.tunnel.calls.isEmpty }

        // Exactly one trailing reload, and no fallback stop/start. After the
        // trailing fire nothing is pending, so this cannot under-count.
        XCTAssertEqual(fixture.tunnel.calls, [.reload])
        XCTAssertNil(fixture.state.lastErrorMessage)
    }

    // MARK: - Fixture

    private struct Fixture {
        let state: AppState
        let tunnel: TunnelControllerMock
        let builder: ConfigBuilderMock
        let node: ProxyNode
    }

    /// Builds an `AppState` on mocks, drives it into `.tun` mode with one
    /// selected manual node, and marks the mock tunnel active — the state
    /// every test starts from. Uses only public `AppState` surface.
    private func makeTunReadyFixture() async throws -> Fixture {
        let supportDirectory = try makeSupportDirectory()
        let tunnel = TunnelControllerMock()
        let builder = ConfigBuilderMock()
        let dependencies = AppDependencies(
            coreRunner: CoreRunnerMock(),
            systemProxy: SystemProxyMock(),
            configBuilder: builder,
            subscriptionParser: SubscriptionParserMock(),
            configValidator: ConfigValidatorMock(),
            loginItem: LoginItemMock(),
            makeClashAPI: { _ in ClashAPIMock() },
            tunnelController: tunnel
        )
        let state = AppState(dependencies: dependencies, supportDirectoryURL: supportDirectory)

        // The TUN fallback start re-runs binary discovery; point the override
        // at any executable so `locateSingBoxBinary()` succeeds. The binary is
        // never launched — the validator and core runner are mocks.
        var prefs = state.preferences
        prefs.singBoxBinaryPathOverride = "/bin/ls"
        await state.updatePreferences(prefs)
        await state.setProxyMode(.tun)

        let node = ProxyNode(
            name: "node-a",
            protocolType: .shadowsocks,
            server: "a.example.com",
            port: 443,
            password: "secret",
            method: "aes-128-gcm"
        )
        state.addManualNode(node)  // Auto-selects the first node.
        tunnel.isActive = true
        return Fixture(state: state, tunnel: tunnel, builder: builder, node: node)
    }

    /// A fresh per-test support directory, removed on teardown.
    private func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linko-appstate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Tunnel mock

/// Records the lifecycle calls `AppState` makes against `TunnelControlling`
/// and fails on demand, so tests can assert the exact fallback sequence.
@MainActor
private final class TunnelControllerMock: TunnelControlling {
    enum Call: Equatable {
        case start
        case stop
        case reload
    }

    /// Mirrors `TunnelController.isActive`; tests flip it to simulate a
    /// running tunnel. `stop()` clears it like a real teardown would.
    var isActive = false
    var startError: Error?
    var reloadError: Error?

    private(set) var calls: [Call] = []
    private(set) var startedConfigs: [String] = []
    private(set) var reloadedConfigs: [String] = []

    private let statusSubject = CurrentValueSubject<NEVPNStatus, Never>(.invalid)
    var status: NEVPNStatus { statusSubject.value }
    var statusPublisher: AnyPublisher<NEVPNStatus, Never> { statusSubject.eraseToAnyPublisher() }

    func load() async {}

    func start(configJSON: String) async throws {
        calls.append(.start)
        startedConfigs.append(configJSON)
        if let startError { throw startError }
    }

    func stop() {
        calls.append(.stop)
        isActive = false
    }

    func reload(configJSON: String) async throws {
        calls.append(.reload)
        reloadedConfigs.append(configJSON)
        if let reloadError { throw reloadError }
    }
}

// MARK: - Service mocks

/// Emits JSON carrying the nodes' servers so tests can assert which node set
/// a config handed to the tunnel was built from. Throws on demand to simulate
/// an unrepresentable config.
private final class ConfigBuilderMock: SingBoxConfigBuilding {
    var buildError: Error?
    private(set) var buildCount = 0

    func build(nodes: [ProxyNode], preferences: AppPreferences) throws -> Data {
        buildCount += 1
        if let buildError { throw buildError }
        let servers = nodes.map(\.server).joined(separator: ",")
        return Data(#"{"servers":"\#(servers)"}"#.utf8)
    }

    func outboundTags(for nodes: [ProxyNode]) -> [String] {
        nodes.map(\.name)
    }

    func validate(nodes: [ProxyNode], routing: RoutingConfig) throws -> [String] {
        []
    }
}

private final class CoreRunnerMock: CoreRunning {
    var state: CoreState = .stopped
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
    var onStateChange: (@Sendable (CoreState) -> Void)?

    func start(binaryURL: URL, configFileURL: URL, logFileURL: URL) throws {
        state = .running(pid: 1)
    }

    func stop() {
        state = .stopped
    }
}

private final class SystemProxyMock: SystemProxyRunning {
    private(set) var isEnabled = false

    func enable(host: String, port: Int) throws { isEnabled = true }
    func disable() throws { isEnabled = false }
    func restorePersistedSnapshotIfPresent() throws -> Bool { false }
}

private struct SubscriptionParserMock: SubscriptionParsing {
    func parse(clashYAML: String) throws -> SubscriptionParseResult {
        SubscriptionParseResult(nodes: [])
    }
    func parse(subscription content: String) throws -> SubscriptionParseResult {
        SubscriptionParseResult(nodes: [])
    }
}

/// Always valid: the TUN tests exercise reload/fallback sequencing, not
/// pre-flight validation (covered by LinkoKit's ConfigValidatorTests).
private struct ConfigValidatorMock: ConfigValidating {
    func validate(configFileURL: URL, binaryURL: URL) -> ConfigValidationResult {
        ConfigValidationResult(isValid: true, errors: [], warnings: [])
    }
}

private struct LoginItemMock: LoginItemControlling {
    var status: LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

/// Inert Clash API: `select` succeeds instantly so the post-reload node
/// re-selection never retries/sleeps; observability calls are unused here.
private struct ClashAPIMock: ClashAPIProviding {
    struct Unused: Error {}

    func version() async throws -> String { "mock" }
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
