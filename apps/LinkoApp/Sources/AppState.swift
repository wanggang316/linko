import AppKit
import Combine
import Foundation
import LinkoKit

/// A user-facing error carrying a localized (Chinese) message.
struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Central orchestrator for the menu bar app: owns preferences, imported
/// subscriptions, the sing-box core lifecycle, the macOS system proxy state,
/// and the Clash API interactions. All state is MainActor-bound.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState(dependencies: .live())

    // MARK: - Published state

    @Published private(set) var preferences: AppPreferences
    @Published private(set) var subscriptions: [LinkoKit.Subscription]
    @Published private(set) var coreState: CoreState = .stopped
    @Published private(set) var isSystemProxyEnabled = false
    @Published private(set) var isSwitchingProxy = false
    @Published private(set) var isTestingDelays = false
    /// Last measured delay (ms) per node id; cleared when the core stops.
    @Published private(set) var nodeDelays: [UUID: Int] = [:]
    /// Last error/notice message surfaced in the menu, if any.
    @Published var lastErrorMessage: String?

    // MARK: - Dependencies

    private let coreRunner: CoreRunning
    private let systemProxy: SystemProxyRunning
    private let configBuilder: SingBoxConfigBuilding
    private let subscriptionParser: SubscriptionParsing
    private let makeClashAPI: (URL) -> ClashAPIProviding

    // MARK: - Lifecycle serialization

    /// Tail of the serialized lifecycle-operation chain. Every proxy
    /// lifecycle mutation (toggle, restart, core-death handling) is appended
    /// here so operations can never interleave across their await points.
    private var lifecycleTask: Task<Void, Never>?
    /// Number of queued/running lifecycle operations; drives `isSwitchingProxy`.
    private var pendingLifecycleOperations = 0 {
        didSet { isSwitchingProxy = pendingLifecycleOperations > 0 }
    }

    // MARK: - Storage locations

    private let supportDirectoryURL: URL

    private var preferencesFileURL: URL { supportDirectoryURL.appendingPathComponent("preferences.json") }
    private var subscriptionsFileURL: URL { supportDirectoryURL.appendingPathComponent("subscriptions.json") }
    private var configFileURL: URL { supportDirectoryURL.appendingPathComponent("config.json") }
    private var logFileURL: URL { supportDirectoryURL.appendingPathComponent("core.log") }

    // MARK: - Init

    init(
        dependencies: AppDependencies,
        supportDirectoryURL: URL = AppState.defaultSupportDirectoryURL()
    ) {
        self.coreRunner = dependencies.coreRunner
        self.systemProxy = dependencies.systemProxy
        self.configBuilder = dependencies.configBuilder
        self.subscriptionParser = dependencies.subscriptionParser
        self.makeClashAPI = dependencies.makeClashAPI
        self.supportDirectoryURL = supportDirectoryURL
        self.preferences = Self.loadJSON(
            AppPreferences.self,
            from: supportDirectoryURL.appendingPathComponent("preferences.json")
        ) ?? .default
        self.subscriptions = Self.loadJSON(
            [LinkoKit.Subscription].self,
            from: supportDirectoryURL.appendingPathComponent("subscriptions.json")
        ) ?? []

        // React immediately when the core dies in the background; otherwise
        // the system proxy keeps routing traffic to a dead local port until
        // the user happens to open the menu.
        self.coreRunner.onStateChange = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runSerializedLifecycle { [weak self] in
                    self?.handleCoreStateChange()
                }
            }
        }
    }

    static func defaultSupportDirectoryURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linko", isDirectory: true)
    }

    // MARK: - Derived state

    var allNodes: [ProxyNode] {
        subscriptions.flatMap(\.nodes)
    }

    var selectedNode: ProxyNode? {
        allNodes.first { $0.id == preferences.selectedNodeID }
    }

    var isBinaryAvailable: Bool {
        locateSingBoxBinary() != nil
    }

    // MARK: - System proxy toggle

    func setSystemProxy(enabled: Bool) async {
        guard !isSwitchingProxy, enabled != isSystemProxyEnabled else { return }
        await runSerializedLifecycle { [self] in
            // Re-check: a queued restart/toggle may have changed the state by
            // the time this operation runs.
            guard enabled != isSystemProxyEnabled else { return }
            if enabled {
                await startProxying()
            } else {
                stopProxying()
            }
        }
    }

    /// Appends `operation` to the serialized lifecycle chain and waits for it.
    /// All proxy lifecycle mutations funnel through here so a toggle can never
    /// interleave with a restart (or another toggle) across await points.
    private func runSerializedLifecycle(_ operation: @escaping @MainActor () async -> Void) async {
        pendingLifecycleOperations += 1
        defer { pendingLifecycleOperations -= 1 }
        let previous = lifecycleTask
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lifecycleTask = task
        await task.value
    }

    private func startProxying() async {
        lastErrorMessage = nil
        let nodes = allNodes
        guard !nodes.isEmpty else {
            lastErrorMessage = "暂无可用节点，请先导入订阅。"
            return
        }
        guard let binaryURL = locateSingBoxBinary() else {
            coreState = .failed(reason: "sing-box binary not found")
            lastErrorMessage = "未找到 sing-box：请在设置中指定路径，或运行 scripts/fetch-singbox.sh，或执行 brew install sing-box。"
            return
        }
        if preferences.selectedNodeID == nil || selectedNode == nil {
            preferences.selectedNodeID = nodes.first?.id
            persistPreferences()
        }
        do {
            try writeConfigFile(nodes: nodes)
            try coreRunner.start(binaryURL: binaryURL, configFileURL: configFileURL, logFileURL: logFileURL)
            coreState = coreRunner.state
            try systemProxy.enable(host: "127.0.0.1", port: preferences.mixedPort)
            isSystemProxyEnabled = true
            await applySelectedNodeViaClashAPI()
            // Pick up an early crash (e.g. invalid config) after the grace period.
            coreState = coreRunner.state
            if case .failed(let reason) = coreState {
                try? systemProxy.disable()
                isSystemProxyEnabled = false
                lastErrorMessage = "sing-box 启动失败：\(reason)"
            }
        } catch {
            if isSystemProxyEnabled {
                try? systemProxy.disable()
                isSystemProxyEnabled = false
            }
            coreRunner.stop()
            coreState = .failed(reason: error.localizedDescription)
            lastErrorMessage = "开启系统代理失败：\(error.localizedDescription)"
        }
    }

    private func stopProxying() {
        if isSystemProxyEnabled {
            do {
                try systemProxy.disable()
            } catch {
                lastErrorMessage = "恢复系统代理设置失败：\(error.localizedDescription)"
            }
            isSystemProxyEnabled = false
        }
        coreRunner.stop()
        coreState = .stopped
        nodeDelays = [:]
    }

    private func restartProxying() async {
        await runSerializedLifecycle { [self] in
            guard isSystemProxyEnabled else { return }
            stopProxying()
            await startProxying()
        }
    }

    /// Reacts to core state transitions reported by `CoreRunner` (hopped to
    /// the main actor and serialized with the other lifecycle operations).
    /// A core that dies while the system proxy is on must immediately release
    /// the user's network settings instead of routing traffic to a dead port.
    private func handleCoreStateChange() {
        // Re-read the live state: a queued restart may already have moved on
        // by the time this operation runs.
        switch coreRunner.state {
        case .running(let pid):
            coreState = .running(pid: pid)
        case .stopped:
            // Stops are always initiated by AppState, which updates coreState
            // itself (sometimes to .failed with a richer reason); don't
            // overwrite that here.
            break
        case .failed(let reason):
            coreState = .failed(reason: reason)
            if isSystemProxyEnabled {
                try? systemProxy.disable()
                isSystemProxyEnabled = false
                nodeDelays = [:]
                lastErrorMessage = "sing-box 已意外退出：\(reason)"
            }
        }
    }

    /// Re-reads the core process state; called when the menu opens so a core
    /// that died in the background is reflected (and the proxy restored).
    func refreshCoreState() {
        guard isSystemProxyEnabled || coreRunner.isRunning else { return }
        coreState = coreRunner.state
        if case .failed(let reason) = coreState, isSystemProxyEnabled {
            try? systemProxy.disable()
            isSystemProxyEnabled = false
            lastErrorMessage = "sing-box 已意外退出：\(reason)"
        }
    }

    /// Restores system proxy settings left behind by a previous session that
    /// crashed or was force-quit while the proxy was enabled. Called once at
    /// launch, before the proxy can be toggled.
    func recoverFromPreviousSession() {
        do {
            if try systemProxy.restorePersistedSnapshotIfPresent() {
                lastErrorMessage = "已恢复上次会话遗留的系统代理设置。"
            }
        } catch {
            lastErrorMessage = "恢复上次会话的系统代理设置失败：\(error.localizedDescription)"
        }
    }

    /// Called on app termination and from the quit menu item.
    func shutdown() {
        if isSystemProxyEnabled {
            try? systemProxy.disable()
            isSystemProxyEnabled = false
        }
        coreRunner.stop()
        coreState = .stopped
    }

    // MARK: - Node selection

    /// The sing-box outbound tag assigned to `node` by the config builder.
    /// Display names may collide across subscriptions (the builder dedupes
    /// them), so every Clash API call must use the tag, never the raw name.
    private func outboundTag(for node: ProxyNode) -> String {
        let nodes = allNodes
        let tags = configBuilder.outboundTags(for: nodes)
        guard
            let index = nodes.firstIndex(where: { $0.id == node.id }),
            index < tags.count
        else {
            return node.name
        }
        return tags[index]
    }

    func selectNode(id: UUID?) {
        guard preferences.selectedNodeID != id else { return }
        preferences.selectedNodeID = id
        persistPreferences()
        guard coreRunner.isRunning, let node = allNodes.first(where: { $0.id == id }) else { return }
        let api = clashAPIClient()
        let tag = outboundTag(for: node)
        Task {
            do {
                try await api.select(selector: "proxy", nodeName: tag)
            } catch {
                // Selector update failed; fall back to config regeneration + restart.
                await self.restartProxying()
            }
        }
    }

    /// Pushes the persisted node selection to the selector once the Clash API
    /// becomes reachable after core startup. Best effort with retries.
    private func applySelectedNodeViaClashAPI() async {
        guard let node = selectedNode else { return }
        let api = clashAPIClient()
        let tag = outboundTag(for: node)
        for attempt in 0..<5 {
            do {
                try await api.select(selector: "proxy", nodeName: tag)
                return
            } catch {
                if attempt < 4 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    // MARK: - Delay testing

    func testDelays() {
        guard !isTestingDelays else { return }
        guard case .running = coreState else {
            lastErrorMessage = "开启系统代理后才能测延迟。"
            return
        }
        isTestingDelays = true
        let nodes = allNodes
        // Delay queries must use the deduplicated outbound tags: with
        // duplicate display names, querying by name would return the first
        // node's delay for every duplicate.
        let tags = configBuilder.outboundTags(for: nodes)
        let api = clashAPIClient()
        let testURL = preferences.delayTestURL
        Task {
            let results = await withTaskGroup(of: (UUID, Int?).self, returning: [UUID: Int].self) { group in
                for (node, tag) in zip(nodes, tags) {
                    let nodeID = node.id
                    group.addTask {
                        let delay = try? await api.delay(
                            nodeName: tag,
                            testURL: testURL,
                            timeoutMilliseconds: 5000
                        )
                        return (nodeID, delay)
                    }
                }
                var collected: [UUID: Int] = [:]
                for await (nodeID, delay) in group {
                    if let delay {
                        collected[nodeID] = delay
                    }
                }
                return collected
            }
            self.nodeDelays = results
            self.isTestingDelays = false
        }
    }

    // MARK: - Subscriptions

    /// Downloads and parses a Clash YAML subscription, persists the result,
    /// and restarts the core if it is running. Returns parser warnings.
    func importSubscription(urlString: String) async throws -> [String] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw AppError(message: "订阅地址无效，请输入 http(s) 链接。")
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw AppError(message: "下载订阅失败：\(error.localizedDescription)")
        }
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw AppError(message: "订阅内容不是合法的 UTF-8 文本。")
        }
        let result: SubscriptionParseResult
        do {
            result = try subscriptionParser.parse(clashYAML: yaml)
        } catch {
            throw AppError(message: "订阅解析失败：不是合法的 Clash YAML。")
        }
        guard !result.nodes.isEmpty else {
            throw AppError(message: "订阅中没有可识别的节点。")
        }

        var subscription = LinkoKit.Subscription(
            name: url.host ?? "订阅",
            url: url,
            lastUpdated: Date(),
            nodes: result.nodes
        )
        if let index = subscriptions.firstIndex(where: { $0.url == url }) {
            subscription.id = subscriptions[index].id
            subscription.name = subscriptions[index].name
            subscriptions[index] = subscription
        } else {
            subscriptions.append(subscription)
        }
        persistSubscriptions()

        if selectedNode == nil {
            preferences.selectedNodeID = allNodes.first?.id
            persistPreferences()
        }
        await restartProxying()
        return result.warnings
    }

    // MARK: - Preferences

    func updatePreferences(_ newPreferences: AppPreferences) async {
        let old = preferences
        guard old != newPreferences else { return }
        preferences = newPreferences
        persistPreferences()
        let coreAffecting = old.mixedPort != newPreferences.mixedPort
            || old.clashAPIPort != newPreferences.clashAPIPort
            || old.singBoxBinaryPathOverride != newPreferences.singBoxBinaryPathOverride
        if coreAffecting {
            await restartProxying()
        }
    }

    // MARK: - Binary discovery

    /// Discovery order: user override → repo vendor binary (development runs
    /// from the repo root) → Homebrew → /usr/local.
    func locateSingBoxBinary() -> URL? {
        var candidates: [String] = []
        if let override = preferences.singBoxBinaryPathOverride,
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            candidates.append((override as NSString).expandingTildeInPath)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("sing-box").path {
            candidates.append(bundled)
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/vendor/sing-box/sing-box")
        candidates.append("/opt/homebrew/bin/sing-box")
        candidates.append("/usr/local/bin/sing-box")
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Private helpers

    private func clashAPIClient() -> ClashAPIProviding {
        // Port is bounded by settings validation; the URL is always valid.
        makeClashAPI(URL(string: "http://127.0.0.1:\(preferences.clashAPIPort)")!)
    }

    private func writeConfigFile(nodes: [ProxyNode]) throws {
        try ensureSupportDirectory()
        let data = try configBuilder.build(nodes: nodes, preferences: preferences)
        try data.write(to: configFileURL, options: .atomic)
    }

    private func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
    }

    // MARK: - Persistence

    private static func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func persistJSON(_ value: some Encodable, to url: URL, what: String) {
        do {
            try ensureSupportDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            lastErrorMessage = "保存\(what)失败：\(error.localizedDescription)"
        }
    }

    private func persistPreferences() {
        persistJSON(preferences, to: preferencesFileURL, what: "偏好设置")
    }

    private func persistSubscriptions() {
        persistJSON(subscriptions, to: subscriptionsFileURL, what: "订阅")
    }
}
