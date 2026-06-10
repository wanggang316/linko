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
    private let configValidator: ConfigValidating
    private let loginItem: LoginItemControlling
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

    /// Drives the background subscription auto-update loop. Owned here so it
    /// survives across turns and is cancelled/rescheduled on pref changes.
    private let autoUpdateScheduler = AutoUpdateScheduler()

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
        self.configValidator = dependencies.configValidator
        self.loginItem = dependencies.loginItem
        self.makeClashAPI = dependencies.makeClashAPI
        self.supportDirectoryURL = supportDirectoryURL

        // Load persisted state. A *corrupt* file (present but undecodable) must
        // not be silently dropped: we back it up alongside the original and
        // surface a notice, so the user can recover their data instead of
        // unknowingly starting from defaults. An *absent* file is a normal first
        // run and stays silent.
        var loadNotices: [String] = []
        let loadedPreferences = Self.loadJSON(
            AppPreferences.self,
            from: supportDirectoryURL.appendingPathComponent("preferences.json"),
            what: "偏好设置",
            notices: &loadNotices
        )
        self.preferences = loadedPreferences ?? .default
        self.subscriptions = Self.loadJSON(
            [LinkoKit.Subscription].self,
            from: supportDirectoryURL.appendingPathComponent("subscriptions.json"),
            what: "订阅",
            notices: &loadNotices
        ) ?? []
        if !loadNotices.isEmpty {
            self.lastErrorMessage = loadNotices.joined(separator: "\n")
        }

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

        // Start the background subscription auto-update loop if the user had
        // it enabled in a previous session.
        rescheduleAutoUpdate()
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
            // PRE-FLIGHT VALIDATION (flagship safety feature): run
            // `sing-box check` on the generated config before touching the
            // core or the system proxy. On FATAL/ERROR we refuse to start, so
            // a bad node/rule/DNS block can never silently break the user's
            // network — the exact failure class we fixed for DNS.
            // Run the checker off the main actor: it blocks on a subprocess
            // (`sing-box check`), and we don't want to park the UI on it.
            let validator = configValidator
            let configURL = configFileURL
            let validation = await Task.detached {
                validator.validate(configFileURL: configURL, binaryURL: binaryURL)
            }.value
            guard validation.isValid else {
                coreState = .failed(reason: validation.errorSummary)
                lastErrorMessage = "配置校验未通过，已阻止启动：\(validation.errorSummary)"
                return
            }
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
        let url: URL
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        } else if
            let parsed = URL(string: trimmed),
            let scheme = parsed.scheme?.lowercased(),
            scheme == "http" || scheme == "https" || scheme == "file" {
            url = parsed
        } else {
            throw AppError(message: "订阅地址无效，请输入 http(s) 链接或本地文件路径。")
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

        // Capture the node selected before the merge: the parser mints fresh
        // UUIDs on every parse, so refreshing the backing subscription would
        // otherwise orphan the persisted `selectedNodeID`. We re-map it onto
        // the re-parsed node for the same server afterwards.
        let previousSelected = selectedNode

        let subscription = LinkoKit.Subscription(
            name: url.host ?? url.deletingPathExtension().lastPathComponent,
            url: url,
            lastUpdated: Date(),
            nodes: result.nodes
        )
        // Merge-by-url upsert: re-importing the same URL replaces that
        // subscription in place (preserving its id + user-assigned name)
        // instead of creating a duplicate.
        subscriptions = SubscriptionStore.upsert(subscription, into: subscriptions)
        persistSubscriptions()

        // Re-map the selection across the refresh (matched by server identity),
        // then fall back to the first available node if nothing survived.
        let remapped = SubscriptionStore.remapSelection(
            previousSelected: previousSelected,
            subscriptions: subscriptions
        )
        let newSelection = remapped ?? SubscriptionStore.firstNodeID(in: subscriptions)
        if preferences.selectedNodeID != newSelection {
            preferences.selectedNodeID = newSelection
            persistPreferences()
        }

        // Only restart the core when this import can change what the running
        // config routes through: it supplies the selected node. A refresh of
        // an unrelated subscription leaves the running config untouched.
        if isSystemProxyEnabled, importAffectsRunningConfig(updatedURL: url) {
            await restartProxying()
        }
        return result.warnings
    }

    /// Whether re-importing the subscription at `updatedURL` changes the
    /// running config — i.e. it backs the currently selected node. Evaluated
    /// after the upsert + re-map so it reflects the freshly parsed nodes.
    private func importAffectsRunningConfig(updatedURL: URL) -> Bool {
        guard let selectedID = preferences.selectedNodeID,
              let subscription = subscriptions.first(where: { $0.url == updatedURL })
        else { return false }
        return subscription.nodes.contains { $0.id == selectedID }
    }

    // MARK: - Subscription management (public surface)
    //
    // These are the documented contracts the Services agents implement against.
    // `addSubscription` is the named entry point for the management UI; it
    // currently delegates to `importSubscription`. The per-subscription
    // operations re-fetch via the (transport-complete) `SubscriptionParser`,
    // persist, and trigger a *validated* restart when the running config is
    // affected.

    /// Adds a subscription from a URL or local file path. Returns parser
    /// warnings. Equivalent to `importSubscription` and kept as the named
    /// management-UI entry point.
    @discardableResult
    func addSubscription(urlString: String) async throws -> [String] {
        try await importSubscription(urlString: urlString)
    }

    /// Re-downloads and re-parses the subscription with `id`, replacing its
    /// nodes, updating `lastUpdated`, and (if it backs the running config)
    /// triggering a validated restart. Returns parser warnings.
    /// Filled in by the Subscriptions Services agent.
    @discardableResult
    func refreshSubscription(id: UUID) async throws -> [String] {
        guard let subscription = subscriptions.first(where: { $0.id == id }) else {
            throw AppError(message: "未找到要刷新的订阅。")
        }
        return try await importSubscription(urlString: subscription.url.absoluteString)
    }

    /// Refreshes every subscription. Per-subscription failures are collected
    /// rather than aborting the batch. Returns the aggregated warnings.
    /// Filled in by the Subscriptions Services agent.
    @discardableResult
    func refreshAllSubscriptions() async -> [String] {
        var warnings: [String] = []
        for subscription in subscriptions {
            do {
                warnings += try await refreshSubscription(id: subscription.id)
            } catch {
                warnings.append("刷新「\(subscription.name)」失败：\(error.localizedDescription)")
            }
        }
        return warnings
    }

    /// Renames the subscription with `id`. Persists. Does not touch the core.
    func renameSubscription(id: UUID, to name: String) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        subscriptions[index].name = trimmed
        persistSubscriptions()
    }

    /// Removes the subscription with `id`. If it backed the selected node or
    /// the running config, the selection is repaired and a validated restart
    /// is triggered. Filled in by the Subscriptions Services agent.
    func removeSubscription(id: UUID) async {
        guard subscriptions.contains(where: { $0.id == id }) else { return }
        // Did the removed subscription back the running config's selected node?
        let backedSelection = SubscriptionStore.subscriptionBacksSelection(
            id: id,
            selectedNodeID: preferences.selectedNodeID,
            subscriptions: subscriptions
        )
        subscriptions.removeAll { $0.id == id }
        persistSubscriptions()
        if backedSelection {
            preferences.selectedNodeID = SubscriptionStore.firstNodeID(in: subscriptions)
            persistPreferences()
        }
        // Only restart when the removal actually changed what the running
        // config routes through; removing an unrelated subscription is a no-op
        // for the core.
        if isSystemProxyEnabled, backedSelection {
            await restartProxying()
        }
    }

    /// Enables/disables automatic subscription refresh and sets the interval
    /// (minutes, clamped to `AppPreferences.minAutoUpdateMinutes`). Persists
    /// and (re)schedules the background refresh Task. Filled in by the
    /// Subscriptions Services agent.
    func setAutoUpdate(enabled: Bool, intervalMinutes: Int) async {
        var updated = preferences
        updated.subscriptionAutoUpdateEnabled = enabled
        updated.subscriptionAutoUpdateMinutes = AppPreferences.clampInterval(intervalMinutes)
        await updatePreferences(updated)
        rescheduleAutoUpdate()
    }

    /// Cancels and (if enabled) restarts the background auto-update loop to
    /// match the current preferences. Delegates the `Task` lifecycle to
    /// `AutoUpdateScheduler` and the interval math to `LinkoKit.AutoUpdateSchedule`.
    private func rescheduleAutoUpdate() {
        autoUpdateScheduler.reschedule(
            enabled: preferences.subscriptionAutoUpdateEnabled,
            intervalMinutes: preferences.subscriptionAutoUpdateMinutes
        ) { [weak self] in
            // Skip ticks while a lifecycle operation (toggle/restart) is in
            // flight so an auto-refresh can't race a user-initiated switch.
            guard let self, !self.isSwitchingProxy else { return }
            _ = await self.refreshAllSubscriptions()
        }
    }

    // MARK: - Launch at login (public surface)

    /// Current "launch at login" registration status, for the Settings toggle.
    var loginItemStatus: LoginItemStatus {
        loginItem.status
    }

    /// Registers/unregisters the app as a login item and mirrors the intent
    /// into preferences. Surfaces failures via `lastErrorMessage`.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
            var updated = preferences
            updated.launchAtLogin = enabled
            preferences = updated
            persistPreferences()
        } catch {
            lastErrorMessage = "设置开机自启动失败：\(error.localizedDescription)"
        }
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

    // MARK: - Observability access (dashboard)

    /// `true` while the core process is alive — the precondition for the Clash
    /// API streams to carry data. The dashboard view model polls this to decide
    /// whether to (re)subscribe.
    var isCoreRunning: Bool {
        coreRunner.isRunning
    }

    /// Builds a Clash API client bound to the live `clashAPIPort`, for callers
    /// outside the lifecycle path (the dashboard's traffic/connections/logs
    /// streams). Rebuild after the port changes; existing streams keep their
    /// old client until restarted.
    func makeClashAPIClient() -> ClashAPIProviding {
        clashAPIClient()
    }

    // MARK: - Window helpers

    /// Brings the app to the foreground and surfaces the given window. Required
    /// because linko runs as an accessory app (`LSUIElement`), so a window must
    /// be paired with an explicit activation to come to front from the menu.
    func openWindow(id: String, using openWindow: (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id)
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

    /// Loads and decodes persisted JSON. Distinguishes three outcomes:
    /// - file absent / unreadable → `nil`, silent (normal first run);
    /// - file present but undecodable → the corrupt file is backed up (so the
    ///   user can recover it) and a notice is appended to `notices`, then `nil`;
    /// - decodable → the value.
    /// This guarantees a corrupted preferences/subscriptions file is never
    /// silently discarded into defaults.
    private static func loadJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        what: String,
        notices: inout [String]
    ) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let backupURL = backUpCorruptFile(at: url)
            if let backupURL {
                notices.append("\(what)文件已损坏，无法读取，已备份到 \(backupURL.lastPathComponent) 并改用默认值。")
            } else {
                notices.append("\(what)文件已损坏，无法读取，已改用默认值。")
            }
            return nil
        }
    }

    /// Moves a corrupt persisted file aside to a timestamped `.corrupt-…`
    /// sibling so the user can recover it. Returns the backup URL, or `nil` if
    /// the move failed (in which case the original is left untouched).
    private static func backUpCorruptFile(at url: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        do {
            // Remove a stale backup at the same path (extremely unlikely given
            // the timestamp), then move the corrupt original aside.
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.moveItem(at: url, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
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
