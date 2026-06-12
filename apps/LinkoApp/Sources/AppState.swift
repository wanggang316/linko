import AppKit
import Combine
import Foundation
import LinkoKit
import NetworkExtension

/// A user-facing error carrying a localized (Chinese) message.
struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Result of an import from the import sheet: what format was recognized, how
/// many nodes were added, where they went (a refreshable subscription vs.
/// manual nodes), and any per-entry parser warnings.
struct NodeImportOutcome {
    enum Target: Equatable {
        case subscription(name: String)
        case manualNodes
    }

    let format: SubscriptionFormat
    let addedNodeCount: Int
    let warnings: [String]
    let target: Target

    /// A one-line Chinese summary for the import sheet.
    var summary: String {
        switch target {
        case .subscription(let name):
            return "识别为\(format.displayName)，已导入订阅「\(name)」，共 \(addedNodeCount) 个节点。"
        case .manualNodes:
            return "识别为\(format.displayName)，已添加 \(addedNodeCount) 个手动节点。"
        }
    }
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
    /// Hand-added nodes that belong to no subscription — the user's own
    /// editable/deletable entries. Mirrors `profiles.active.manualNodes`; every
    /// edit folds back into the active profile via `syncActiveProfile()`.
    @Published private(set) var manualNodes: [ProxyNode]
    /// Value-type summaries of every stored profile, in order. Mirrors
    /// `profiles` and is the binding source for the profile management UI.
    @Published private(set) var profileSummaries: [ProfileSummary] = []
    /// The id of the active profile (drives selection highlighting in the UI).
    @Published private(set) var activeProfileID: UUID
    @Published private(set) var coreState: CoreState = .stopped
    @Published private(set) var isSystemProxyEnabled = false
    @Published private(set) var isSwitchingProxy = false
    /// Live TUN tunnel status, mirrored from the NetworkExtension. Only
    /// meaningful in `.tun` proxy mode; `.invalid`/`.disconnected` otherwise.
    @Published private(set) var tunnelStatus: NEVPNStatus = .invalid
    @Published private(set) var isTestingDelays = false
    /// Last measured delay (ms) per node id; cleared when the core stops.
    @Published private(set) var nodeDelays: [UUID: Int] = [:]
    /// Last error/notice message surfaced in the menu, if any.
    @Published var lastErrorMessage: String?
    /// Global network-based auto-switch configuration (rules mapping the current
    /// network to a profile). Persisted separately from any profile.
    @Published private(set) var networkSwitch: NetworkSwitchConfig
    /// The latest detected network environment, surfaced in the switch editor so
    /// the user can see what their rules will match against. `nil` until the
    /// path monitor reports its first update.
    @Published private(set) var currentNetwork: NetworkSnapshot?

    // MARK: - Dependencies

    private let coreRunner: CoreRunning
    private let systemProxy: SystemProxyRunning
    private let configBuilder: SingBoxConfigBuilding
    private let subscriptionParser: SubscriptionParsing
    private let configValidator: ConfigValidating
    private let loginItem: LoginItemControlling
    private let makeClashAPI: (URL) -> ClashAPIProviding
    /// TUN global mode controller (NetworkExtension). Only used in `.tun` mode.
    let tunnelController: TunnelController
    /// Mirrors `tunnelController.status` into `tunnelStatus`.
    private var tunnelStatusObservation: AnyCancellable?

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

    /// Watches the active network and drives network-based profile switching.
    private let networkMonitor = NetworkMonitor()

    // MARK: - Multi-profile state

    /// The on-disk multi-profile store (`<support>/profiles/`).
    private let profileStore: ProfileStore
    /// Source of truth for the profile set + active pointer. The published
    /// `preferences`/`subscriptions` mirror `profiles.active`; every edit to
    /// them is folded back into this collection and persisted.
    private var profiles: ProfileCollection {
        didSet { refreshProfileSummaries() }
    }

    // MARK: - Storage locations

    private let supportDirectoryURL: URL

    private var preferencesFileURL: URL { supportDirectoryURL.appendingPathComponent("preferences.json") }
    private var subscriptionsFileURL: URL { supportDirectoryURL.appendingPathComponent("subscriptions.json") }
    private var configFileURL: URL { supportDirectoryURL.appendingPathComponent("config.json") }
    private var logFileURL: URL { supportDirectoryURL.appendingPathComponent("core.log") }
    private var networkSwitchFileURL: URL { supportDirectoryURL.appendingPathComponent("network-switch.json") }

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
        self.tunnelController = dependencies.tunnelController
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
        let loadedSubscriptions = Self.loadJSON(
            [LinkoKit.Subscription].self,
            from: supportDirectoryURL.appendingPathComponent("subscriptions.json"),
            what: "订阅",
            notices: &loadNotices
        ) ?? []

        // Load the multi-profile collection. On first run (no `profiles/` dir)
        // the legacy single-config `preferences.json`/`subscriptions.json` are
        // folded losslessly into one active "默认" profile by the store, which
        // we then persist so subsequent launches read from `profiles/`.
        // The global network-switch config persists on its own (it selects
        // between profiles, so it can't live inside one). Absent ⇒ disabled.
        self.networkSwitch = Self.loadJSON(
            NetworkSwitchConfig.self,
            from: supportDirectoryURL.appendingPathComponent("network-switch.json"),
            what: "网络环境切换",
            notices: &loadNotices
        ) ?? .disabled

        let store = ProfileStore(supportDirectoryURL: supportDirectoryURL)
        let collection = store.load(
            legacyPreferences: loadedPreferences,
            legacySubscriptions: loadedSubscriptions
        )
        self.profileStore = store
        self.profiles = collection
        self.activeProfileID = collection.activeProfileID
        // The published single-config state mirrors the active profile.
        self.preferences = collection.active.preferences
        self.subscriptions = collection.active.subscriptions
        self.manualNodes = collection.active.manualNodes

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

        // Mirror the TUN tunnel status into our published mirror, and react to
        // an extension-side disconnect (sleep/wake, manual stop, crash) so the
        // UI and `isSystemProxyEnabled` flag stay truthful in `.tun` mode.
        tunnelStatusObservation = tunnelController.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.tunnelStatus = status
                self.handleTunnelStatusChange(status)
            }
        // Pick up an already-installed provider configuration (so a previously
        // approved extension is reflected and reusable without re-prompting).
        Task { await tunnelController.load() }

        // Seed the published summaries (the `didSet` does not fire during init)
        // and persist the collection so a first-run migration is written out.
        refreshProfileSummaries()
        try? profileStore.save(collection)

        // Start the background subscription auto-update loop if the user had
        // it enabled in a previous session.
        rescheduleAutoUpdate()

        // Begin watching the network so network-based profile switching can
        // react to environment changes. The callback is a no-op while the
        // feature is off, so this is safe to start unconditionally.
        networkMonitor.onChange = { [weak self] snapshot in
            self?.handleNetworkChange(snapshot)
        }
        networkMonitor.start()
    }

    static func defaultSupportDirectoryURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linko", isDirectory: true)
    }

    // MARK: - Derived state

    var allNodes: [ProxyNode] {
        subscriptions.flatMap(\.nodes) + manualNodes
    }

    var selectedNode: ProxyNode? {
        allNodes.first { $0.id == preferences.selectedNodeID }
    }

    var isBinaryAvailable: Bool {
        locateSingBoxBinary() != nil
    }

    /// Kills any lingering sing-box process launched from `binaryURL` — an
    /// orphan left behind when a previous app instance crashed or was
    /// force-killed before it could stop its child. Without this, the orphan
    /// keeps holding the inbound port and the next start fails to bind. Matches
    /// on the exact binary path so it never touches an unrelated sing-box (e.g.
    /// a Homebrew install the user runs separately).
    private static func terminateStaleCore(binaryURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", binaryURL.path]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Proxy toggle (mode-aware)

    /// The single on/off entry point for the menu switch, dispatched by the
    /// active `proxyMode`. In `.systemProxy` mode this drives the sing-box
    /// subprocess + macOS system proxy (the M1 path, untouched). In `.tun`
    /// mode it drives the `LinkoTunnel` NetworkExtension instead — no
    /// subprocess, no system-proxy mutation.
    func setSystemProxy(enabled: Bool) async {
        guard !isSwitchingProxy, enabled != isProxyActive else { return }
        await runSerializedLifecycle { [self] in
            // Re-check: a queued restart/toggle may have changed the state by
            // the time this operation runs.
            guard enabled != isProxyActive else { return }
            switch preferences.proxyMode {
            case .systemProxy:
                if enabled { await startProxying() } else { stopProxying() }
            case .tun:
                if enabled { await startTunnel() } else { await stopTunnel() }
            }
        }
    }

    /// Whether traffic is currently being intercepted in *either* mode. The
    /// menu switch binds to this so it reflects the active mode's real state.
    var isProxyActive: Bool {
        switch preferences.proxyMode {
        case .systemProxy: return isSystemProxyEnabled
        case .tun: return tunnelController.isActive
        }
    }

    // MARK: - Proxy mode switching

    /// Switches the proxy interception mode. If a tunnel/proxy is currently
    /// active, it is torn down in the old mode and brought back up in the new
    /// one so the switch is seamless from the user's perspective. Persists the
    /// new mode. All of this runs on the serialized lifecycle chain.
    func setProxyMode(_ mode: ProxyMode) async {
        guard preferences.proxyMode != mode else { return }
        await runSerializedLifecycle { [self] in
            guard preferences.proxyMode != mode else { return }
            let wasActive = isProxyActive
            // Tear down whatever the *current* mode has running.
            switch preferences.proxyMode {
            case .systemProxy:
                if isSystemProxyEnabled { stopProxying() }
            case .tun:
                if tunnelController.isActive { await stopTunnelInternal() }
            }
            preferences.proxyMode = mode
            persistPreferences()
            lastErrorMessage = nil
            // Bring the new mode up only if the user had it on before.
            guard wasActive else { return }
            switch mode {
            case .systemProxy:
                await startProxying()
            case .tun:
                await startTunnel()
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
            // If a previous run crashed (or was force-killed), its sing-box
            // child is orphaned and still holds the inbound port, so a fresh
            // start would fail with "address already in use". Reap any stale
            // instance of our own binary before launching.
            Self.terminateStaleCore(binaryURL: binaryURL)
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

    /// Re-applies the generated config to whatever is currently running,
    /// dispatched by mode. Called when a config-affecting change lands
    /// (subscription import/removal that backs the selected node, a port
    /// change, a failed selector update). A no-op when nothing is active.
    ///
    /// - `.systemProxy`: restarts the sing-box subprocess (the M1 behavior).
    /// - `.tun`: hot-reloads the running tunnel in place via the extension's
    ///   `handleAppMessage`; on reload failure it falls back to a full
    ///   stop/start of the tunnel so the user is never left on a stale config.
    private func reconfigureRunningProxy() async {
        switch preferences.proxyMode {
        case .systemProxy:
            await restartProxying()
        case .tun:
            await runSerializedLifecycle { [self] in
                guard tunnelController.isActive else { return }
                let nodes = allNodes
                guard !nodes.isEmpty,
                      let configData = try? buildTunConfig(nodes: nodes),
                      let configJSON = String(data: configData, encoding: .utf8)
                else { return }
                do {
                    try await tunnelController.reload(configJSON: configJSON)
                    await applySelectedNodeViaClashAPI()
                } catch {
                    // Reload failed; fall back to a clean restart of the tunnel.
                    await stopTunnelInternal()
                    await startTunnel()
                }
            }
        }
    }

    // MARK: - TUN global mode (NetworkExtension)

    /// Generates a validated `.tun` config and starts the `LinkoTunnel`
    /// NetworkExtension. Mirrors `startProxying`'s safety contract: pre-flight
    /// validation runs before the tunnel is touched, so a bad node/rule/DNS
    /// block can never bring up a broken global tunnel. Never spawns the core
    /// subprocess and never mutates the system proxy.
    private func startTunnel() async {
        lastErrorMessage = nil
        let nodes = allNodes
        guard !nodes.isEmpty else {
            lastErrorMessage = "暂无可用节点，请先导入订阅。"
            return
        }
        guard let binaryURL = locateSingBoxBinary() else {
            coreState = .failed(reason: "sing-box binary not found")
            lastErrorMessage = "未找到 sing-box：TUN 配置校验需要核心二进制，请在设置中指定路径或安装核心。"
            return
        }
        if preferences.selectedNodeID == nil || selectedNode == nil {
            preferences.selectedNodeID = nodes.first?.id
            persistPreferences()
        }
        do {
            // Build the .tun config (tun inbound + auto_route + gVisor) and run
            // the same pre-flight `sing-box check` we use for system-proxy mode
            // before handing it to the extension.
            let configData = try buildTunConfig(nodes: nodes)
            try writeConfigFile(data: configData)
            let validator = configValidator
            let configURL = configFileURL
            let validation = await Task.detached {
                validator.validate(configFileURL: configURL, binaryURL: binaryURL)
            }.value
            guard validation.isValid else {
                coreState = .failed(reason: validation.errorSummary)
                lastErrorMessage = "TUN 配置校验未通过，已阻止启动：\(validation.errorSummary)"
                return
            }
            guard let configJSON = String(data: configData, encoding: .utf8) else {
                lastErrorMessage = "TUN 配置编码失败。"
                return
            }
            // Hands the JSON to the extension (App Group file + inline option)
            // and starts the tunnel. The extension runs sing-box via libbox and
            // calls back to configure the utun interface.
            try await tunnelController.start(configJSON: configJSON)
            // The Clash API is served from inside the extension on
            // 127.0.0.1:<clashAPIPort>; reflect "running" so the dashboard and
            // node selection use it. Actual readiness is confirmed when the
            // tunnel reaches `.connected` (see handleTunnelStatusChange).
            coreState = .running(pid: 0)
            await applySelectedNodeViaClashAPI()
        } catch {
            coreState = .failed(reason: error.localizedDescription)
            lastErrorMessage = "开启 TUN 全局模式失败：\(error.localizedDescription)"
        }
    }

    /// User-initiated stop of the TUN tunnel (serialized via the toggle path).
    private func stopTunnel() async {
        await stopTunnelInternal()
    }

    /// Stops the tunnel and resets derived state. Shared by `stopTunnel`,
    /// mode-switching, and shutdown.
    private func stopTunnelInternal() async {
        tunnelController.stop()
        coreState = .stopped
        nodeDelays = [:]
    }

    /// Reacts to NetworkExtension status changes. An extension that disconnects
    /// on its own (manual stop from System Settings, sleep/wake, a crash) must
    /// be reflected in `coreState` so the menu doesn't claim the tunnel is up.
    /// Only acts in `.tun` mode; ignored entirely in `.systemProxy` mode.
    private func handleTunnelStatusChange(_ status: NEVPNStatus) {
        guard preferences.proxyMode == .tun else { return }
        switch status {
        case .connected:
            coreState = .running(pid: 0)
        case .disconnected, .invalid:
            // Don't clobber a `.failed` reason we set ourselves on a start error.
            if case .failed = coreState { return }
            coreState = .stopped
            nodeDelays = [:]
        case .connecting, .reasserting, .disconnecting:
            break
        @unknown default:
            break
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

    /// Re-reads the active mode's state; called when the menu opens so a core
    /// (or tunnel) that died in the background is reflected (and the system
    /// proxy restored, in `.systemProxy` mode).
    func refreshCoreState() {
        if preferences.proxyMode == .tun {
            // The tunnel status is published live; mirror it so coreState
            // tracks an extension-side disconnect even if the notification was
            // missed while the popover was closed.
            tunnelStatus = tunnelController.status
            handleTunnelStatusChange(tunnelStatus)
            return
        }
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
        // Tear down the TUN tunnel too (no-op if not running). The extension
        // also stops itself when the app process exits, but stopping
        // explicitly restores the network promptly on a clean quit.
        tunnelController.stop()
        networkMonitor.stop()
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
        // The Clash selector is reachable whenever the active mode is serving
        // traffic: the subprocess in `.systemProxy` mode, or the in-extension
        // sing-box (also on 127.0.0.1:<clashAPIPort>) in `.tun` mode.
        guard isClashAPIReachable, let node = allNodes.first(where: { $0.id == id }) else { return }
        let api = clashAPIClient()
        let tag = outboundTag(for: node)
        Task {
            do {
                try await api.select(selector: "proxy", nodeName: tag)
            } catch {
                // Selector update failed; fall back to config regeneration +
                // restart/reload of the active mode.
                await self.reconfigureRunningProxy()
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

    // MARK: - URL scheme / CLI commands

    /// Dispatches a `linko://` command (from the app's URL handler or the
    /// `scripts/linko` CLI) onto the existing control surface. Privileged
    /// commands are confirmed with the user first: a webpage can open a custom
    /// URL, so importing a remote config without consent would be unsafe.
    func handle(command: LinkoCommand) async {
        switch command {
        case .enableProxy:
            await setSystemProxy(enabled: true)
        case .disableProxy:
            await setSystemProxy(enabled: false)
        case .toggleProxy:
            await setSystemProxy(enabled: !isProxyActive)
        case let .setMode(mode):
            await setProxyMode(mode)
        case let .selectNode(name):
            selectNodeByName(name)
        case let .switchProfile(name):
            await switchProfileByName(name)
        case .testDelays:
            testDelays()
        case let .installConfig(url, name):
            await confirmAndInstall(url: url, name: name)
        }
    }

    /// Selects the first node whose display name matches `name`
    /// (case-insensitively). Surfaces a notice when nothing matches.
    private func selectNodeByName(_ name: String) {
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let node = allNodes.first(where: {
            $0.name.trimmingCharacters(in: .whitespaces).lowercased() == target
        }) else {
            lastErrorMessage = "未找到名为「\(name)」的节点。"
            return
        }
        selectNode(id: node.id)
    }

    /// Switches to the first profile whose name matches `name`.
    private func switchProfileByName(_ name: String) async {
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let summary = profileSummaries.first(where: {
            $0.name.trimmingCharacters(in: .whitespaces).lowercased() == target
        }) else {
            lastErrorMessage = "未找到名为「\(name)」的配置档案。"
            return
        }
        await switchProfile(id: summary.id)
    }

    /// Confirms with the user, then imports a subscription from `url`. The
    /// confirmation is the trust boundary: the URL can originate from a webpage
    /// that opened `linko://install-config`, so we never fetch + trust it
    /// silently. An optional `name` renames the subscription after import.
    private func confirmAndInstall(url: URL, name: String?) async {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "导入订阅？"
        alert.informativeText = "Linko 收到一个导入订阅的请求：\n\(url.absoluteString)\n\n仅在你信任该来源时导入。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try await importSubscription(urlString: url.absoluteString)
            if let name, !name.isEmpty,
               let sub = subscriptions.first(where: { $0.url == url }) {
                renameSubscription(id: sub.id, to: name)
            }
            lastErrorMessage = "已从 URL 导入订阅。"
        } catch {
            lastErrorMessage = (error as? AppError)?.message ?? "导入订阅失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Network-based profile switching

    /// Reacts to a network environment change: records it for the UI, then
    /// re-evaluates the switch rules. Switching is app-level — sing-box has no
    /// SUBNET primitive — so a matching rule swaps the whole active profile.
    private func handleNetworkChange(_ snapshot: NetworkSnapshot) {
        currentNetwork = snapshot
        applyNetworkSwitch()
    }

    /// Evaluates the switch rules against the current network and switches to
    /// the matched profile when it differs from the active one. A no-op while
    /// the feature is off, no network is known yet, nothing matches, or the
    /// target profile no longer exists.
    private func applyNetworkSwitch() {
        guard networkSwitch.isEnabled, let snapshot = currentNetwork else { return }
        guard let targetID = NetworkSwitchEvaluator.matchedProfileID(
            rules: networkSwitch.rules, snapshot: snapshot
        ) else { return }
        guard targetID != activeProfileID,
              profileSummaries.contains(where: { $0.id == targetID })
        else { return }
        Task { await switchProfile(id: targetID) }
    }

    /// Turns network-based switching on/off. Enabling re-evaluates immediately
    /// against the current network so the right profile applies right away.
    func setNetworkSwitchEnabled(_ enabled: Bool) {
        guard networkSwitch.isEnabled != enabled else { return }
        networkSwitch.isEnabled = enabled
        persistNetworkSwitch()
        if enabled { applyNetworkSwitch() }
    }

    /// Appends a switch rule and persists.
    func addNetworkSwitchRule(_ rule: NetworkSwitchRule) {
        networkSwitch.rules.append(rule)
        persistNetworkSwitch()
        applyNetworkSwitch()
    }

    /// Replaces the rule with the same id, persists, and re-evaluates.
    func updateNetworkSwitchRule(_ rule: NetworkSwitchRule) {
        guard let index = networkSwitch.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        networkSwitch.rules[index] = rule
        persistNetworkSwitch()
        applyNetworkSwitch()
    }

    /// Removes the rule with `id` and persists.
    func deleteNetworkSwitchRule(id: UUID) {
        networkSwitch.rules.removeAll { $0.id == id }
        persistNetworkSwitch()
    }

    private func persistNetworkSwitch() {
        persistJSON(networkSwitch, to: networkSwitchFileURL, what: "网络环境切换")
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

    /// One-shot entry point for the import sheet: a fetchable subscription URL /
    /// file path becomes a refreshable subscription, while pasted node link(s)
    /// or raw config content (no URL to refresh) become manual nodes. Auto-
    /// detects the format (Clash YAML / Base64 V2Ray subscription / share links)
    /// and reports it so the UI can explain what it understood.
    @discardableResult
    func importFromInput(_ text: String) async throws -> NodeImportOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError(message: "请输入订阅链接、节点链接或配置内容。")
        }
        if isFetchableSource(trimmed) {
            return try await importSubscriptionDetailed(urlString: trimmed)
        }
        return try importPastedNodes(trimmed)
    }

    /// Whether `input` names a subscription we can fetch + refresh: an http(s)
    /// URL or a local file path. Bare share links (`ss://…`, multi-line link
    /// lists, Base64 blobs) are not fetchable and import as manual nodes instead.
    private func isFetchableSource(_ input: String) -> Bool {
        if input.hasPrefix("/") || input.hasPrefix("~") { return true }
        if let url = URL(string: input), let scheme = url.scheme?.lowercased() {
            return scheme == "http" || scheme == "https" || scheme == "file"
        }
        return false
    }

    /// Downloads and parses a subscription, persists the result, and restarts
    /// the core if it is running. Returns parser warnings.
    @discardableResult
    func importSubscription(urlString: String) async throws -> [String] {
        try await importSubscriptionDetailed(urlString: urlString).warnings
    }

    /// The detailed import that backs both `importSubscription` and the import
    /// sheet: fetches the URL / file, auto-detects the format, upserts a
    /// subscription, and re-maps the selection. Returns the recognized format +
    /// node count alongside warnings.
    func importSubscriptionDetailed(urlString: String) async throws -> NodeImportOutcome {
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
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppError(message: "订阅内容不是合法的 UTF-8 文本。")
        }
        let result: SubscriptionParseResult
        do {
            result = try subscriptionParser.parse(subscription: text)
        } catch {
            throw AppError(message: "订阅解析失败：无法识别为 Clash、V2Ray(Base64) 或节点链接格式。")
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

        // Only reconfigure the running proxy when this import can change what
        // the running config routes through: it supplies the selected node. A
        // refresh of an unrelated subscription leaves the running config
        // untouched. Mode-aware: restarts the subprocess (.systemProxy) or
        // hot-reloads the tunnel (.tun).
        if isProxyActive, importAffectsRunningConfig(updatedURL: url) {
            await reconfigureRunningProxy()
        }
        let finalName = subscriptions.first(where: { $0.url == url })?.name ?? subscription.name
        return NodeImportOutcome(
            format: result.format,
            addedNodeCount: result.nodes.count,
            warnings: result.warnings,
            target: .subscription(name: finalName)
        )
    }

    /// Imports pasted node link(s) / raw content (no fetchable URL) as manual
    /// nodes. Auto-detects the format and reports it. Throws when nothing parses.
    private func importPastedNodes(_ content: String) throws -> NodeImportOutcome {
        let result: SubscriptionParseResult
        do {
            result = try subscriptionParser.parse(subscription: content)
        } catch {
            throw AppError(message: "无法识别：请粘贴 ss/vmess/vless/trojan/hysteria2/tuic 节点链接、V2Ray(Base64) 订阅，或 Clash 配置内容。")
        }
        guard !result.nodes.isEmpty else {
            throw AppError(message: "没有可识别的节点。")
        }
        addManualNodes(result.nodes)
        return NodeImportOutcome(
            format: result.format,
            addedNodeCount: result.nodes.count,
            warnings: result.warnings,
            target: .manualNodes
        )
    }

    /// Appends several manual nodes in one persist, selecting the first when
    /// nothing was selected yet (so a first paste becomes usable immediately).
    private func addManualNodes(_ nodes: [ProxyNode]) {
        guard !nodes.isEmpty else { return }
        manualNodes.append(contentsOf: nodes)
        persistManualNodes()
        if preferences.selectedNodeID == nil, let first = nodes.first {
            selectNode(id: first.id)
        }
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
        // Only reconfigure when the removal actually changed what the running
        // config routes through; removing an unrelated subscription is a no-op.
        // Mode-aware (subprocess restart vs. tunnel reload).
        if isProxyActive, backedSelection {
            await reconfigureRunningProxy()
        }
    }

    // MARK: - Manual node management
    //
    // Manual nodes are the user's hand-added, fully editable entries
    // (subscription nodes stay read-only because a refresh overwrites them).
    // They live in `manualNodes`, are appended after subscription nodes in
    // `allNodes`, and flow into the generated config exactly like any other
    // node. Every mutation persists by folding back into the active profile.

    /// Whether `id` is a hand-added manual node — the editable/deletable set.
    /// The UI uses this to decide whether to offer edit/delete, or only the
    /// read-only detail plus "复制为可编辑节点".
    func isManualNode(_ id: UUID) -> Bool {
        manualNodes.contains { $0.id == id }
    }

    /// Appends a new manual node and persists. Selects it when nothing was
    /// selected yet so the first hand-added node becomes usable immediately;
    /// otherwise the selection is untouched (a brand-new node is not routed
    /// until the user picks it, so the running config is undisturbed).
    func addManualNode(_ node: ProxyNode) {
        manualNodes.append(node)
        persistManualNodes()
        if preferences.selectedNodeID == nil {
            selectNode(id: node.id)
        }
    }

    /// Replaces the manual node sharing `node.id`. If it is the node currently
    /// routing traffic, the running config is regenerated so the edit takes
    /// effect at once. Non-manual ids (subscription nodes) are ignored.
    func updateManualNode(_ node: ProxyNode) async {
        guard let index = manualNodes.firstIndex(where: { $0.id == node.id }) else { return }
        manualNodes[index] = node
        nodeDelays[node.id] = nil  // server/credentials may have changed; stale delay.
        persistManualNodes()
        if isProxyActive, preferences.selectedNodeID == node.id {
            await reconfigureRunningProxy()
        }
    }

    /// Removes the manual node with `id`. If it backed the selection, the
    /// selection is repaired to the first remaining node and (when running) the
    /// config is regenerated. Non-manual ids are ignored.
    func removeManualNode(id: UUID) async {
        guard manualNodes.contains(where: { $0.id == id }) else { return }
        let backedSelection = preferences.selectedNodeID == id
        manualNodes.removeAll { $0.id == id }
        nodeDelays[id] = nil
        persistManualNodes()
        if backedSelection {
            preferences.selectedNodeID = allNodes.first?.id
            persistPreferences()
            if isProxyActive {
                await reconfigureRunningProxy()
            }
        }
    }

    /// Clones any node — subscription or manual — into an independent, editable
    /// manual node with a fresh id and a deduplicated "（副本）" name, then
    /// returns the new node's id so the caller can open it in the editor. This
    /// is how a read-only subscription node becomes editable without fighting
    /// the refresh semantics that would overwrite an in-place edit.
    @discardableResult
    func duplicateNodeToManual(id: UUID) -> UUID? {
        guard let source = allNodes.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = uniqueManualNodeName(base: source.name + "（副本）")
        manualNodes.append(copy)
        persistManualNodes()
        return copy.id
    }

    /// A manual-node name not already taken by another manual node, appending a
    /// numeric suffix on collision so duplicates stay distinguishable.
    private func uniqueManualNodeName(base: String) -> String {
        let existing = Set(manualNodes.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
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

    /// Updates non-mode preferences. A change to `proxyMode` must go through
    /// `setProxyMode` (which handles teardown/bring-up); this method ignores a
    /// `proxyMode` delta to avoid silently flipping modes without lifecycle
    /// handling.
    func updatePreferences(_ newPreferences: AppPreferences) async {
        let old = preferences
        guard old != newPreferences else { return }
        var newPreferences = newPreferences
        // Preserve the live mode: mode switches are handled exclusively by
        // `setProxyMode`.
        newPreferences.proxyMode = old.proxyMode
        guard old != newPreferences else { return }
        preferences = newPreferences
        persistPreferences()
        let coreAffecting = old.mixedPort != newPreferences.mixedPort
            || old.clashAPIPort != newPreferences.clashAPIPort
            || old.singBoxBinaryPathOverride != newPreferences.singBoxBinaryPathOverride
        if coreAffecting {
            await reconfigureRunningProxy()
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

    /// `true` while a sing-box instance is serving the Clash API — the
    /// precondition for the dashboard streams to carry data. In `.systemProxy`
    /// mode this is the subprocess; in `.tun` mode it is the in-extension
    /// sing-box, alive once the tunnel is connected. The dashboard view model
    /// polls this to decide whether to (re)subscribe.
    var isCoreRunning: Bool {
        isClashAPIReachable
    }

    /// Whether the active mode is currently serving the Clash API on
    /// 127.0.0.1:<clashAPIPort>. Drives node selection, delay testing, and the
    /// dashboard streams uniformly across both modes.
    var isClashAPIReachable: Bool {
        switch preferences.proxyMode {
        case .systemProxy:
            return coreRunner.isRunning
        case .tun:
            return tunnelStatus == .connected
        }
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
        let data = try configBuilder.build(nodes: nodes, preferences: preferences)
        try writeConfigFile(data: data)
    }

    /// Persists already-built config JSON to the support-directory config file
    /// used as the pre-flight validation target.
    private func writeConfigFile(data: Data) throws {
        try ensureSupportDirectory()
        try data.write(to: configFileURL, options: .atomic)
    }

    // MARK: - Config-file inspection

    /// Regenerates the active profile's sing-box config from the current nodes +
    /// preferences and returns its on-disk URL — the exact JSON the core runs in
    /// system-proxy mode. Surfacing the generated config keeps linko auditable:
    /// the user can read (and, for debugging, hand-tweak) the real configuration.
    /// The file is rebuilt on every start / node change, so manual edits are
    /// transient. Returns `nil` (with a surfaced notice) if the build fails.
    @discardableResult
    func regenerateConfigFileForInspection() -> URL? {
        do {
            try writeConfigFile(nodes: allNodes)
            return configFileURL
        } catch {
            lastErrorMessage = "生成配置文件失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// Opens the freshly-generated sing-box config in the user's default editor
    /// for the `.json` type. A no-op (with a surfaced notice) if generation fails.
    func openConfigFileInEditor() {
        guard let url = regenerateConfigFileForInspection() else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveals the freshly-generated sing-box config in Finder.
    func revealConfigFileInFinder() {
        guard let url = regenerateConfigFileForInspection() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Builds a `.tun`-mode sing-box config regardless of the persisted mode.
    /// Used by the TUN start path (the mode is already `.tun` there, but this
    /// makes the intent explicit and independent of caller ordering).
    private func buildTunConfig(nodes: [ProxyNode]) throws -> Data {
        var tunPreferences = preferences
        tunPreferences.proxyMode = .tun
        return try configBuilder.build(nodes: nodes, preferences: tunPreferences)
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
        syncActiveProfile()
    }

    private func persistSubscriptions() {
        persistJSON(subscriptions, to: subscriptionsFileURL, what: "订阅")
        syncActiveProfile()
    }

    /// Manual nodes live only inside the profile (no legacy mirror file), so
    /// persisting them is just a fold-back into the active profile on disk.
    private func persistManualNodes() {
        syncActiveProfile()
    }

    // MARK: - Profile synchronization

    /// Folds the current published `preferences` + `subscriptions` back into the
    /// active profile and persists the whole collection. Called from every edit
    /// path (`persistPreferences`/`persistSubscriptions`) so an import, node
    /// selection, mode change, port change, or routing edit lands in the active
    /// profile on disk. The legacy `preferences.json`/`subscriptions.json` are
    /// still written for backward compatibility.
    private func syncActiveProfile() {
        var active = profiles.active
        // Skip a redundant write when nothing actually changed.
        guard active.preferences != preferences
            || active.subscriptions != subscriptions
            || active.manualNodes != manualNodes
        else { return }
        active.preferences = preferences
        active.subscriptions = subscriptions
        active.manualNodes = manualNodes
        profiles = ProfileStore.upsert(active, in: profiles)
        saveProfiles()
    }

    /// Persists `profiles` to disk, surfacing a failure as a notice rather than
    /// crashing (the in-memory collection remains the source of truth).
    private func saveProfiles() {
        do {
            try profileStore.save(profiles)
        } catch {
            lastErrorMessage = "保存配置档案失败：\(error.localizedDescription)"
        }
    }

    /// Recomputes the published `[ProfileSummary]` and `activeProfileID` from the
    /// current collection (the cheap, node-free projection the UI binds to).
    private func refreshProfileSummaries() {
        let active = profiles.activeProfileID
        activeProfileID = active
        profileSummaries = profiles.profiles.map { ProfileSummary(profile: $0, activeProfileID: active) }
    }
}

// MARK: - ProfileManaging

/// `AppState`'s profile-management surface. Every mutating op persists the
/// collection; `switchProfile` (and the create/duplicate/delete paths that imply
/// a switch) re-generate + validate + restart on the serialized lifecycle chain.
extension AppState: ProfileManaging {

    /// Creates a new empty profile named `name` (de-duplicated) and switches to
    /// it (re-generating + validating + restarting if the core is running).
    /// Returns the new profile's id.
    @discardableResult
    func createProfile(named name: String) async -> UUID {
        let (collection, created) = ProfileStore.create(name: name, in: profiles)
        profiles = collection
        saveProfiles()
        await activateAndApply(id: created.id)
        return created.id
    }

    /// Deep-duplicates the profile with `id` (fresh node ids, re-pointed
    /// selection) and switches to the copy. Returns the copy's id, or `nil` if
    /// `id` is unknown.
    @discardableResult
    func duplicateProfile(id: UUID) async -> UUID? {
        let result: (collection: ProfileCollection, created: Profile)
        do {
            result = try ProfileStore.duplicate(id: id, in: profiles)
        } catch {
            lastErrorMessage = (error as? ProfileStoreError)?.errorDescription
                ?? "复制配置档案失败：\(error.localizedDescription)"
            return nil
        }
        profiles = result.collection
        saveProfiles()
        await activateAndApply(id: result.created.id)
        return result.created.id
    }

    /// Renames the profile with `id`. Persists. Does not touch the running core.
    /// When the active profile is renamed the summary list refreshes in place.
    func renameProfile(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            profiles = try ProfileStore.rename(id: id, to: trimmed, in: profiles)
        } catch {
            lastErrorMessage = (error as? ProfileStoreError)?.errorDescription
                ?? "重命名配置档案失败：\(error.localizedDescription)"
            return
        }
        saveProfiles()
    }

    /// Deletes the profile with `id`. When the deleted profile was active,
    /// activation moves to a neighbor and the core is re-generated/restarted onto
    /// it. A no-op (with a surfaced notice) when `id` is the last profile.
    func deleteProfile(id: UUID) async {
        let wasActive = (id == profiles.activeProfileID)
        let updated: ProfileCollection
        do {
            updated = try ProfileStore.delete(id: id, in: profiles)
        } catch {
            lastErrorMessage = (error as? ProfileStoreError)?.errorDescription
                ?? "删除配置档案失败：\(error.localizedDescription)"
            return
        }
        profiles = updated
        saveProfiles()
        if wasActive {
            // The active pointer moved to a neighbor; bring the core onto it.
            await activateAndApply(id: profiles.activeProfileID)
        }
    }

    /// Switches the active profile to `id`: swaps in its subscriptions +
    /// preferences, re-generates + validates the config, and restarts the core
    /// if running. A no-op when `id` is already active. On validation failure the
    /// switch is aborted and the prior active profile left in place.
    func switchProfile(id: UUID) async {
        guard id != profiles.activeProfileID else { return }
        guard profiles.profiles.contains(where: { $0.id == id }) else {
            lastErrorMessage = ProfileStoreError.profileNotFound(id).errorDescription
            return
        }
        await activateAndApply(id: id)
    }

    /// Shared activation pipeline: marks `id` active in the collection, mirrors
    /// its preferences/subscriptions into the published state, and (on the
    /// serialized lifecycle chain) regenerates + validates + restarts the core.
    /// A validation failure rolls the active pointer + published state back to
    /// the previously active profile, so a bad profile can never strand the user.
    private func activateAndApply(id: UUID) async {
        guard let activated = try? ProfileStore.activate(id: id, in: profiles) else {
            lastErrorMessage = ProfileStoreError.profileNotFound(id).errorDescription
            return
        }
        // Snapshot for rollback before any state is mutated.
        let previousCollection = profiles
        let previousPreferences = preferences
        let previousSubscriptions = subscriptions
        let previousManualNodes = manualNodes
        let target = activated.active

        await runSerializedLifecycle { [self] in
            // Was the *previous* profile's mode serving traffic? Read this
            // before reassigning `preferences`, since `isProxyActive` keys off
            // the current mode.
            let wasActive = isProxyActive
            // Tear down whatever the previous profile had running.
            switch previousPreferences.proxyMode {
            case .systemProxy:
                if isSystemProxyEnabled { stopProxying() }
            case .tun:
                if tunnelController.isActive { await stopTunnelInternal() }
            }

            // Swap the published single-config state to the target profile. We
            // assign directly (not via setProxyMode/updatePreferences) so the
            // new profile's mode/ports/routing all apply atomically.
            applyActiveProfile(collection: activated, profile: target)
            lastErrorMessage = nil

            // Only bring the core up if the previous profile had it on.
            guard wasActive else { return }
            switch preferences.proxyMode {
            case .systemProxy:
                await startProxying()
            case .tun:
                await startTunnel()
            }

            // On a validation/startup failure, restore the previous profile so a
            // broken switch never strands the user offline.
            if case .failed(let reason) = coreState {
                let collectionRollback = previousCollection
                applyActiveProfile(
                    collection: collectionRollback,
                    profile: collectionRollback.active,
                    preferencesOverride: previousPreferences,
                    subscriptionsOverride: previousSubscriptions,
                    manualNodesOverride: previousManualNodes
                )
                lastErrorMessage = "切换配置档案失败，已恢复上一个档案：\(reason)"
                switch preferences.proxyMode {
                case .systemProxy:
                    await startProxying()
                case .tun:
                    await startTunnel()
                }
            }
        }
    }

    /// Adopts `profile` as the active one: updates the collection, mirrors its
    /// preferences/subscriptions into the published state, rewrites the legacy
    /// mirror files, persists the collection, and reschedules auto-update. The
    /// overrides let the rollback path restore the exact prior published values.
    private func applyActiveProfile(
        collection: ProfileCollection,
        profile: Profile,
        preferencesOverride: AppPreferences? = nil,
        subscriptionsOverride: [LinkoKit.Subscription]? = nil,
        manualNodesOverride: [ProxyNode]? = nil
    ) {
        profiles = collection
        preferences = preferencesOverride ?? profile.preferences
        subscriptions = subscriptionsOverride ?? profile.subscriptions
        manualNodes = manualNodesOverride ?? profile.manualNodes
        persistJSON(preferences, to: preferencesFileURL, what: "偏好设置")
        persistJSON(subscriptions, to: subscriptionsFileURL, what: "订阅")
        saveProfiles()
        rescheduleAutoUpdate()
    }
}
