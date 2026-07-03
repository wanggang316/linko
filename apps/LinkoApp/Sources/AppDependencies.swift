import Combine
import Foundation
import LinkoKit
import NetworkExtension

/// The TUN-tunnel surface `AppState` drives, extracted from the concrete
/// `TunnelController` so tests can substitute a mock (a real
/// NetworkExtension can never start inside a unit-test process).
/// `@MainActor` because `AppState` and `TunnelController` are both
/// main-actor-bound.
@MainActor
protocol TunnelControlling: AnyObject {
    /// Live tunnel status, mirrored from the underlying `NEVPNConnection`.
    var status: NEVPNStatus { get }
    /// Publishes every `status` change (the protocol spelling of the
    /// concrete type's `$status`).
    var statusPublisher: AnyPublisher<NEVPNStatus, Never> { get }
    /// `true` while the tunnel is connecting/connected/reasserting.
    var isActive: Bool { get }
    /// Loads any existing saved provider configuration. Idempotent.
    func load() async
    /// Starts the tunnel with the given `.tun` config JSON.
    func start(configJSON: String) async throws
    /// Stops the tunnel; safe to call when already stopped.
    func stop()
    /// Hot-reloads a *running* tunnel with new config JSON; throws when the
    /// tunnel is not running or the reload round-trip fails.
    func reload(configJSON: String) async throws
}

extension TunnelController: TunnelControlling {
    var statusPublisher: AnyPublisher<NEVPNStatus, Never> {
        $status.eraseToAnyPublisher()
    }
}

/// Composition root: bundles the LinkoKit services `AppState` depends on,
/// expressed as protocols so previews/tests can substitute fakes.
@MainActor
struct AppDependencies {
    let coreRunner: CoreRunning
    let systemProxy: SystemProxyRunning
    let configBuilder: SingBoxConfigBuilding
    let subscriptionParser: SubscriptionParsing
    /// Pre-flight validates the generated config (via `sing-box check`) before
    /// the core is started, so a bad node/rule can never silently break the
    /// user's network.
    let configValidator: ConfigValidating
    /// Controls "launch at login" registration (SMAppService.mainApp wrapper).
    let loginItem: LoginItemControlling
    /// Builds a Clash API client for the given base URL. A factory is used
    /// because the API port is user-configurable at runtime.
    let makeClashAPI: (URL) -> ClashAPIProviding
    /// Drives TUN global mode through the `LinkoTunnel` NetworkExtension
    /// (M2). Only consulted in `.tun` proxy mode; `.systemProxy` mode never
    /// touches it.
    let tunnelController: any TunnelControlling

    /// Production wiring backed by the concrete LinkoKit implementations.
    static func live() -> AppDependencies {
        AppDependencies(
            coreRunner: CoreRunner(),
            systemProxy: SystemProxyManager(),
            configBuilder: SingBoxConfigBuilder(),
            subscriptionParser: SubscriptionParser(),
            configValidator: ConfigValidator(),
            loginItem: LoginItemService(),
            makeClashAPI: { baseURL in ClashAPIClient(baseURL: baseURL) },
            tunnelController: TunnelController()
        )
    }
}
