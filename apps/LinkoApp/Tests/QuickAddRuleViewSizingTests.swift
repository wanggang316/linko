import AppKit
import Combine
import LinkoKit
import NetworkExtension
import SwiftUI
import XCTest

/// Layout tests for the quick-add window. Its scene uses
/// `.windowResizability(.contentSize)`, which hands the window whatever
/// heights `QuickAddRuleView` says it accepts — so these host the view and
/// measure it through the same sizing path.
///
/// Two properties are pinned. The window must have exactly *one* height to
/// choose per state, and it must be the content's own: the view used to
/// stretch from a 320pt floor to unbounded (a greedy `Spacer`), the window
/// settled on a height inside that range, and a three-candidate form came out
/// clipped at both edges — title cut off under the title bar, 取消/添加 cut off
/// below. And that one height must stay *bounded*: the content area scrolls
/// past a cap, so no amount of text can push the buttons out of a window.
@MainActor
final class QuickAddRuleViewSizingTests: XCTestCase {

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

    /// The height tracks what the form actually shows: an IP capture (one
    /// candidate row) is shorter than a bare registrable domain (two) which is
    /// shorter than a subdomain (three) — the state the defect clipped.
    func testWindowHeightGrowsWithTheCandidateList() async throws {
        let ip = try await heightRange(for: .captured(urlString: "http://192.168.1.1:8080/admin")).ideal
        let twoCandidates = try await heightRange(for: .captured(urlString: "https://example.com/")).ideal
        let threeCandidates = try await heightRange(for: .captured(urlString: "https://www.iana.org/")).ideal

        XCTAssertLessThan(ip, twoCandidates, "one candidate row must be shorter than two")
        XCTAssertLessThan(twoCandidates, threeCandidates, "two candidate rows must be shorter than three")
    }

    /// The progress state carries no form, so it must ask for the shortest
    /// window of all — proof the height is not stuck on one value.
    func testCapturingIsTheShortestState() async throws {
        let capturing = try await heightRange(for: .capturing).ideal
        let form = try await heightRange(for: .captured(urlString: "https://example.com/")).ideal

        XCTAssertLessThan(capturing, form)
    }

    /// Every state the flow can render — including the ones that push the most
    /// text into the window (wrapped guidance above the fields, a validation
    /// notice in the footer) — asks for a window that fits on screen.
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

    /// Guidance text is only as short as the frontmost application's name, so
    /// an adversarially long one would otherwise grow the window past the
    /// screen. The content area caps out and scrolls instead.
    func testAnOversizedGuidanceMessageScrollsInsteadOfGrowingTheWindow() async throws {
        let hugeName = String(repeating: "浏览器", count: 400)
        let guidance = QuickAddCapture.guidance(for: .unsupportedApp(name: hugeName))
        XCTAssertGreaterThan(guidance.message.count, 1_000, "the message must be far taller than the window")

        let height = try await heightRange(for: .manual(guidance)).ideal
        XCTAssertLessThanOrEqual(
            height, maximumWindowHeight,
            "the content area must scroll rather than report a \(height)pt window"
        )
    }

    // MARK: - Measurement

    /// Every capture state the window renders, in the shapes the flow can
    /// actually produce. The manual ones double as the validation-notice
    /// case: their form starts empty, which `QuickAddFormModelTests` pins to
    /// a「请输入匹配值」problem — the label the footer shows beside the buttons.
    private static let renderableStates: [QuickAddCaptureState] = [
        .capturing,
        .manual(nil),
        .manual(QuickAddCapture.guidance(for: .permissionDenied(browserName: "Safari"))),
        // An unparseable capture: manual fields plus the prefill notice.
        .captured(urlString: "chrome://settings/"),
        .captured(urlString: "http://192.168.1.1:8080/admin"),
        .captured(urlString: "https://example.com/"),
        .captured(urlString: "https://www.iana.org/"),
        // A host at the RFC 1035 limits: the longest value the parser can ever
        // hand the form.
        .captured(
            urlString: "https://\(String(repeating: "a", count: 63))"
                + ".\(String(repeating: "b", count: 63)).example.com/"
        ),
    ]

    /// The heights `QuickAddRuleView` accepts for a capture state: the
    /// shortest, the ideal, and the tallest. `.windowResizability(.contentSize)`
    /// builds the window's height limits out of exactly these.
    ///
    /// The view is hosted in an off-screen window because the form model is
    /// built in `onAppear`; without a rendered hierarchy every state would
    /// measure as the progress card.
    private func heightRange(for capture: QuickAddCaptureState) async throws -> HeightRange {
        let state = try makeState()
        switch capture {
        case .capturing:
            // Hold the read open: the state stays `.capturing` while measured.
            let gate = Gate()
            state.beginQuickAddCapture {
                await gate.wait()
                return .manual(nil)
            }
            addTeardownBlock { await gate.release() }
        default:
            state.beginQuickAddCapture { capture }
            await waitUntil { state.quickAddCapture == capture }
        }

        let controller = NSHostingController(rootView: QuickAddRuleView().environmentObject(state))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: windowWidth, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        defer { window.contentViewController = nil }

        // Let the run loop turn so SwiftUI renders (and `onAppear` runs)
        // before the sizes are read back.
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

    /// What one capture state lets the window do with its height.
    private struct HeightRange {
        let minimum: CGFloat
        let ideal: CGFloat
        let maximum: CGFloat
    }

    // MARK: - Fixture

    /// An `AppState` on inert mocks with a per-test support directory — the
    /// proxy never starts and nothing touches the developer's machine.
    private func makeState() throws -> AppState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linko-quickadd-sizing-\(UUID().uuidString)", isDirectory: true)
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

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
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

// MARK: - Test plumbing

/// Suspends a capture read until released, so a measurement can run while the
/// window is still showing the progress card.
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
