import Foundation
import LinkoKit

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

    /// Production wiring backed by the concrete LinkoKit implementations.
    static func live() -> AppDependencies {
        AppDependencies(
            coreRunner: CoreRunner(),
            systemProxy: SystemProxyManager(),
            configBuilder: SingBoxConfigBuilder(),
            subscriptionParser: SubscriptionParser(),
            configValidator: ConfigValidator(),
            loginItem: LoginItemService(),
            makeClashAPI: { baseURL in ClashAPIClient(baseURL: baseURL) }
        )
    }
}
