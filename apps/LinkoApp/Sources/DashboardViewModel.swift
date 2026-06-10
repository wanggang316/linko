import Combine
import Foundation
import LinkoKit

/// Drives the Dashboard window: it subscribes to the Clash API's connections,
/// traffic, and logs WebSocket streams and republishes them as bounded,
/// view-ready state. All state is MainActor-bound; the streams are consumed in
/// detached child tasks that are cancelled on `stop()` / `deinit`.
@MainActor
final class DashboardViewModel: ObservableObject {

    // MARK: - Tunables

    /// Cap on the rolling traffic chart buffer (~60s at one tick/second).
    static let trafficHistoryCapacity = 60
    /// Cap on retained log lines; older lines are evicted FIFO.
    static let logCapacity = 500
    /// Initial reconnect backoff after a stream socket drops while the core is
    /// still running. Doubles up to `maxReconnectDelay` to avoid tight-spinning.
    private static let initialReconnectDelay: Duration = .seconds(1)
    /// Upper bound on the reconnect backoff.
    private static let maxReconnectDelay: Duration = .seconds(10)

    // MARK: - Published state

    /// Live connections from the latest `/connections` snapshot, in wire order;
    /// the Connections table applies its own sort comparator on top.
    @Published private(set) var connections: [ClashConnection] = []
    /// Per-application traffic rolled up from the latest `/connections` snapshot,
    /// pre-sorted by descending total bytes for the native per-app (应用) view.
    @Published private(set) var appTrafficStats: [AppTrafficStat] = []
    /// Cumulative downloaded bytes since the core started.
    @Published private(set) var totalDown: Int64 = 0
    /// Cumulative uploaded bytes since the core started.
    @Published private(set) var totalUp: Int64 = 0
    /// Core memory usage in bytes (`0` when unavailable).
    @Published private(set) var memory: UInt64 = 0
    /// Rolling per-second traffic ticks for the chart (≤ `trafficHistoryCapacity`).
    @Published private(set) var trafficHistory: [TrafficSample] = []
    /// Most recent log lines (≤ `logCapacity`), oldest first.
    @Published private(set) var logs: [ClashLogEntry] = []
    /// The log severity currently being streamed.
    @Published var logLevel: ClashLogLevel = .info {
        didSet {
            guard isRunning, oldValue != logLevel else { return }
            restartLogStream()
        }
    }
    /// `true` while the streams are subscribed (the dashboard is "live").
    @Published private(set) var isRunning = false

    // MARK: - Derived state

    /// Number of live connections.
    var connectionCount: Int { connections.count }

    /// Current download rate in bytes for the most recent interval.
    var currentDownRate: Int64 { trafficHistory.last?.down ?? 0 }

    /// Current upload rate in bytes for the most recent interval.
    var currentUpRate: Int64 { trafficHistory.last?.up ?? 0 }

    /// Peak download rate across the retained history (for chart scaling).
    var peakDownRate: Int64 { trafficHistory.map(\.down).max() ?? 0 }

    /// Peak upload rate across the retained history (for chart scaling).
    var peakUpRate: Int64 { trafficHistory.map(\.up).max() ?? 0 }

    // MARK: - Dependencies

    private unowned let appState: AppState
    private var api: ClashAPIProviding?

    // MARK: - Tasks

    private var connectionsTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var logsTask: Task<Void, Never>?
    /// Watches `coreState` so streams start when the core comes up and stop
    /// when it dies, without the view having to drive the lifecycle.
    private var coreStateObservation: AnyCancellable?
    /// Monotonic x-axis index for chart samples.
    private var nextSampleIndex = 0

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Lifecycle

    /// Subscribes to the three streams against the live Clash API port. Begins
    /// observing the core state so subscriptions follow the core's lifecycle.
    /// A no-op while the core is stopped (it will subscribe once it comes up).
    func start() {
        guard !isRunning else { return }
        isRunning = true
        observeCoreState()
        if appState.isCoreRunning {
            subscribeStreams()
        }
    }

    /// Tears down all subscriptions and stops observing the core state. Safe to
    /// call repeatedly; called from the dashboard's `onDisappear` and `deinit`.
    func stop() {
        isRunning = false
        coreStateObservation = nil
        cancelStreams()
    }

    deinit {
        connectionsTask?.cancel()
        trafficTask?.cancel()
        logsTask?.cancel()
    }

    // MARK: - Actions

    /// Closes every live connection (`DELETE /connections`). The stream pushes
    /// the emptied snapshot shortly after.
    func closeAllConnections() {
        guard let api else { return }
        Task { try? await api.closeConnection(id: nil) }
    }

    /// Closes a single connection by id (`DELETE /connections/{id}`).
    func closeConnection(id: String) {
        guard let api else { return }
        Task { try? await api.closeConnection(id: id) }
    }

    /// Clears the retained log buffer (does not affect the core).
    func clearLogs() {
        logs.removeAll(keepingCapacity: true)
    }

    // MARK: - Core-state observation

    private func observeCoreState() {
        coreStateObservation = appState.$coreState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, self.isRunning else { return }
                switch state {
                case .running:
                    if self.connectionsTask == nil { self.subscribeStreams() }
                case .stopped, .failed:
                    self.cancelStreams()
                    self.resetLiveState()
                }
            }
    }

    // MARK: - Stream wiring

    private func subscribeStreams() {
        // Keep a client around for the action methods (closeConnection); each
        // stream loop makes its own fresh client on (re)connect.
        api = appState.makeClashAPIClient()

        connectionsTask = reconnectingTask { viewModel, api in
            for try await snapshot in api.connectionsStream() {
                await viewModel.apply(snapshot: snapshot)
            }
        }

        trafficTask = reconnectingTask { viewModel, api in
            for try await tick in api.trafficStream() {
                await viewModel.apply(tick: tick)
            }
        }

        startLogStream()
    }

    private func startLogStream() {
        let level = logLevel
        logsTask = reconnectingTask { viewModel, api in
            for try await entry in api.logsStream(level: level) {
                await viewModel.append(log: entry)
            }
        }
    }

    private func restartLogStream() {
        logsTask?.cancel()
        logsTask = nil
        guard isRunning, appState.isCoreRunning else { return }
        startLogStream()
    }

    /// Builds a task that consumes a Clash API stream and transparently
    /// reconnects with bounded backoff whenever the socket drops while the core
    /// is still running. It bails (letting `observeCoreState` take over) once the
    /// core stops, the view model stops, or the task is cancelled, so a genuinely
    /// down core never causes a tight reconnect spin.
    private func reconnectingTask(
        _ consume: @escaping (DashboardViewModel, ClashAPIProviding) async throws -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            var delay = Self.initialReconnectDelay
            while !Task.isCancelled {
                guard let self, self.isRunning, self.appState.isCoreRunning else { return }
                let api = self.appState.makeClashAPIClient()
                do {
                    try await consume(self, api)
                    // Stream ended cleanly without error; reset the backoff.
                    delay = Self.initialReconnectDelay
                } catch {
                    // Socket closed/errored; fall through to the backoff below.
                }
                // The loop body returned (closed or errored). If the core is
                // still up, wait a bounded backoff and reconnect; otherwise bail.
                guard !Task.isCancelled, self.isRunning, self.appState.isCoreRunning else { return }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return // Cancelled during the backoff sleep.
                }
                delay = min(delay * 2, Self.maxReconnectDelay)
            }
        }
    }

    private func cancelStreams() {
        connectionsTask?.cancel()
        trafficTask?.cancel()
        logsTask?.cancel()
        connectionsTask = nil
        trafficTask = nil
        logsTask = nil
        api = nil
    }

    private func resetLiveState() {
        connections = []
        appTrafficStats = []
        trafficHistory = []
        nextSampleIndex = 0
        // Cumulative counters are meaningless once the core stops; zero them so
        // the overview doesn't show stale totals from the previous session.
        totalDown = 0
        totalUp = 0
        memory = 0
    }

    // MARK: - Stream application

    private func apply(snapshot: ClashConnectionsSnapshot) {
        // Order is owned by the Table's sort comparator (ConnectionsView), which
        // defaults to newest-first; the snapshot is published unsorted.
        connections = snapshot.connections
        appTrafficStats = AppTrafficAggregator.aggregate(snapshot)
        totalDown = snapshot.downloadTotal
        totalUp = snapshot.uploadTotal
        memory = snapshot.memory
    }

    private func apply(tick: ClashTrafficTick) {
        let sample = TrafficSample(index: nextSampleIndex, up: tick.up, down: tick.down)
        nextSampleIndex += 1
        trafficHistory.append(sample)
        if trafficHistory.count > Self.trafficHistoryCapacity {
            trafficHistory.removeFirst(trafficHistory.count - Self.trafficHistoryCapacity)
        }
    }

    private func append(log entry: ClashLogEntry) {
        logs.append(entry)
        if logs.count > Self.logCapacity {
            logs.removeFirst(logs.count - Self.logCapacity)
        }
    }
}

// MARK: - Chart sample

/// One point on the traffic chart: a per-second `up`/`down` delta tagged with a
/// monotonic index for a stable x-axis as the buffer scrolls.
struct TrafficSample: Identifiable, Equatable, Sendable {
    let index: Int
    let up: Int64
    let down: Int64

    var id: Int { index }
}
