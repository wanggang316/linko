import Foundation
import LinkoKit
import ServiceManagement

/// `LoginItemControlling` backed by `SMAppService.mainApp` (macOS 13+).
///
/// Registers linko to launch at login. No special entitlements are required
/// for a Developer ID app, and it compiles and runs in development. After
/// `register()` the OS may put the item in a "requires approval" state until
/// the user enables it in System Settings > General > Login Items.
struct LoginItemService: LoginItemControlling {
    private var service: SMAppService { .mainApp }

    var status: LoginItemStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        // Registering an already-enabled service throws; treat as success.
        guard service.status != .enabled else { return }
        try service.register()
    }

    func unregister() throws {
        guard service.status != .notRegistered else { return }
        try service.unregister()
    }
}
