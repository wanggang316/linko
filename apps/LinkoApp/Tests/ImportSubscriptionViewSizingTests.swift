import AppKit
import Combine
import LinkoKit
import NetworkExtension
import SwiftUI
import XCTest

/// Layout tests for the import window. Its scene uses
/// `.windowResizability(.contentSize)`, which hands the window whatever heights
/// `ImportSubscriptionView` says it accepts — so these host the view and
/// measure it through the same sizing path `QuickAddRuleViewSizingTests` uses.
///
/// Two properties are pinned. The window must have exactly *one* height to
/// choose per phase, and it must be the content's own: the view used to stretch
/// from a 360pt floor to unbounded (a greedy `Spacer`), so the window settled on
/// a height inside that range and clipped whatever the result area added — the
/// 导入订阅 title cut off under the title bar, 取消/导入 cut off below. And that one
/// height must stay *bounded*: the content area scrolls past a cap, so neither a
/// wrapped download error nor a long list of skipped nodes can push the buttons
/// out of the window.
@MainActor
final class ImportSubscriptionViewSizingTests: XCTestCase {

    /// The width the view pins itself to; every height is measured at it.
    private let windowWidth: CGFloat = 460
    /// Nothing here should ever ask for a window taller than a laptop screen.
    private let maximumWindowHeight: CGFloat = 640

    override func setUp() {
        super.setUp()
        // Rendering an AppKit view hierarchy needs the shared application.
        _ = NSApplication.shared
    }

    /// The regression pin: for every state the view can render, the shortest
    /// and the tallest height it accepts are both its ideal height. A window
    /// sized from that has no room to clip anything.
    func testEveryStateAcceptsExactlyOneHeight() async throws {
        for state in Self.renderableStates {
            let range = try await heightRange(for: state)
            XCTAssertEqual(
                range.minimum, range.ideal, accuracy: 0.5,
                "\(state) can be squeezed to \(range.minimum)pt below its \(range.ideal)pt content"
            )
            XCTAssertEqual(
                range.maximum, range.ideal, accuracy: 0.5,
                "\(state) can be stretched to \(range.maximum)pt above its \(range.ideal)pt content"
            )
        }
    }

    /// The height tracks what the result area actually shows: an idle form is
    /// shorter than one carrying a progress card, an error, or a result — the
    /// states the defect clipped.
    func testTheResultAreaMakesTheWindowTaller() async throws {
        let idle = try await heightRange(for: .empty).ideal
        let statesWithAResultCard: [Scenario] = [
            .importing,
            .failedToParse,
            .finished(skippedNodeCount: 0),
        ]

        for state in statesWithAResultCard {
            let height = try await heightRange(for: state).ideal
            XCTAssertGreaterThan(
                height, idle,
                "\(state) shows a result card, so it must ask for a taller window than the idle form"
            )
        }
    }

    /// The height also tracks how much the result area shows: every skipped
    /// node adds a row, and the window has to grow with the list rather than
    /// clip it.
    func testWindowHeightGrowsWithTheSkippedNodeList() async throws {
        let noWarnings = try await heightRange(for: .finished(skippedNodeCount: 0)).ideal
        let oneWarning = try await heightRange(for: .finished(skippedNodeCount: 1)).ideal
        let threeWarnings = try await heightRange(for: .finished(skippedNodeCount: 3)).ideal

        XCTAssertLessThan(noWarnings, oneWarning, "a skipped-node list must be taller than none")
        XCTAssertLessThan(oneWarning, threeWarnings, "one skipped-node row must be shorter than three")
    }

    /// Every state the flow can render — including the ones that push the most
    /// text into the window (a pasted node list, a wrapped download error, a
    /// long list of skipped nodes) — asks for a window that fits on screen.
    func testEveryStateStaysWithinAWindowThatFitsOnScreen() async throws {
        for state in Self.renderableStates {
            let height = try await heightRange(for: state).ideal
            XCTAssertGreaterThan(height, 0, "\(state) reported no height at all")
            XCTAssertLessThanOrEqual(
                height, maximumWindowHeight,
                "\(state) asks for a \(height)pt window — the content area must scroll instead"
            )
        }
    }

    /// A download failure quotes the underlying error, whose length nothing on
    /// our side bounds. The content area caps out and scrolls instead of
    /// growing the window past the screen.
    func testAnOversizedErrorMessageScrollsInsteadOfGrowingTheWindow() async throws {
        let message = "下载订阅失败：" + String(repeating: "服务器返回了一个无法识别的响应。", count: 80)
        XCTAssertGreaterThan(message.count, 1_000, "the message must be far taller than the window")

        let height = try await heightRange(for: .failed(message: message)).ideal
        XCTAssertLessThanOrEqual(
            height, maximumWindowHeight,
            "the content area must scroll rather than report a \(height)pt window"
        )
    }

    /// A subscription can skip arbitrarily many nodes, so the result list is
    /// unbounded too — and must scroll rather than push 完成 out of the window.
    func testALongSkippedNodeListScrollsInsteadOfGrowingTheWindow() async throws {
        let height = try await heightRange(for: .finished(skippedNodeCount: 200)).ideal
        XCTAssertLessThanOrEqual(
            height, maximumWindowHeight,
            "200 skipped nodes must scroll rather than report a \(height)pt window"
        )
    }

    // MARK: - States

    /// Every phase the window renders, in the shapes the flow can actually
    /// produce, plus the source texts that change the field's own height (empty,
    /// one URL, a pasted link list past the field's 8-line ceiling).
    private static let renderableStates: [Scenario] = [
        .empty,
        .typing,
        .pastedNodeLinks,
        .importing,
        .failedToParse,
        .failed(message: "下载订阅失败：" + String(repeating: "请求超时，请检查网络后重试。", count: 12)),
        .finished(skippedNodeCount: 0),
        .finished(skippedNodeCount: 1),
        .finished(skippedNodeCount: 3),
        .finished(skippedNodeCount: 40),
    ]

    /// One measurable state of the window: what is in the source field and
    /// which phase the import is in.
    private struct Scenario: CustomStringConvertible {
        let description: String
        let sourceText: String
        let phase: ImportSubscriptionView.Phase

        init(_ description: String, sourceText: String, phase: ImportSubscriptionView.Phase) {
            self.description = description
            self.sourceText = sourceText
            self.phase = phase
        }

        /// A source URL long enough to wrap, as a real subscription link does.
        static let subscriptionURL = "https://sub.example.com/link/8f3c1a92e4b7?target=clash&udp=true"

        /// The window as it opens: an empty field, no result.
        static let empty = Scenario("empty", sourceText: "", phase: .idle)

        /// A pasted subscription URL, before the import runs.
        static let typing = Scenario("typing", sourceText: subscriptionURL, phase: .idle)

        /// A multi-line paste — the source field grows to its 8-line ceiling
        /// and this pushes well past it.
        static let pastedNodeLinks = Scenario(
            "pasted node links",
            sourceText: (1...30)
                .map { "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@198.51.100.\($0):8388#节点 \($0)" }
                .joined(separator: "\n"),
            phase: .idle
        )

        /// The progress card, shown while the subscription downloads.
        static let importing = Scenario("importing", sourceText: subscriptionURL, phase: .importing)

        /// The error card, in the wording an unrecognized payload produces.
        static let failedToParse = Scenario(
            "failed to parse",
            sourceText: subscriptionURL,
            phase: .failed("订阅解析失败：无法识别为 Clash、V2Ray(Base64) 或节点链接格式。")
        )

        static func failed(message: String) -> Scenario {
            Scenario("failed (\(message.count) chars)", sourceText: subscriptionURL, phase: .failed(message))
        }

        /// A finished import of a 24-node subscription that skipped
        /// `skippedNodeCount` entries, summarized the way `NodeImportOutcome`
        /// words it for the window.
        static func finished(skippedNodeCount: Int) -> Scenario {
            let outcome = NodeImportOutcome(
                format: .clashYAML,
                addedNodeCount: 24,
                warnings: (0..<skippedNodeCount).map {
                    "跳过链接「ssr://cGFzc3dvcmQtXzEyMzQ1…#节点 \($0 + 1)」：暂不支持 ssr 协议。"
                },
                target: .subscription(name: "sub.example.com")
            )
            return Scenario(
                "finished (\(skippedNodeCount) skipped)",
                sourceText: subscriptionURL,
                phase: .finished(summary: outcome.summary, warnings: outcome.warnings)
            )
        }
    }

    // MARK: - Measurement

    /// The heights `ImportSubscriptionView` accepts for a state: the shortest,
    /// the ideal, and the tallest. `.windowResizability(.contentSize)` builds
    /// the window's height limits out of exactly these.
    ///
    /// The view is hosted in an off-screen window so the measurement runs
    /// through a real render pass, as the window does.
    private func heightRange(for scenario: Scenario) async throws -> HeightRange {
        let controller = NSHostingController(
            rootView: ImportSubscriptionView(sourceText: scenario.sourceText, phase: scenario.phase)
                .environmentObject(try makeState())
        )
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: windowWidth, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        defer { window.contentViewController = nil }

        // Let the run loop turn so SwiftUI renders before the sizes are read back.
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.view.layoutSubtreeIfNeeded()
        return HeightRange(
            minimum: controller.sizeThatFits(in: CGSize(width: windowWidth, height: 0)).height,
            ideal: controller.view.fittingSize.height,
            maximum: controller.sizeThatFits(
                in: CGSize(width: windowWidth, height: 100_000)
            ).height
        )
    }

    /// What one state lets the window do with its height.
    private struct HeightRange {
        let minimum: CGFloat
        let ideal: CGFloat
        let maximum: CGFloat
    }

    // MARK: - Fixture

    /// An `AppState` on inert mocks with a per-test support directory — the
    /// proxy never starts and nothing touches the developer's machine. The view
    /// only reads it when an import runs, which no measurement does.
    private func makeState() throws -> AppState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linko-import-sizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        let dependencies = AppDependencies(
            coreRunner: CoreRunnerStub(),
            systemProxy: SystemProxyStub(),
            configBuilder: ConfigBuilderStub(),
            subscriptionParser: SubscriptionParserStub(),
            configValidator: ConfigValidatorStub(),
            loginItem: LoginItemStub(),
            makeClashAPI: { _ in ClashAPIStub() },
            tunnelController: TunnelControllerStub()
        )
        return AppState(dependencies: dependencies, supportDirectoryURL: url)
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
