import Combine
import Foundation
import LinkoKit
import NetworkExtension

/// App-side controller for TUN global mode (M2).
///
/// Wraps a `NETunnelProviderManager` that installs and drives the
/// `LinkoTunnel` packet-tunnel system extension (bundle id
/// `com.gumpw.linko.tunnel`). Responsibilities:
/// - install/update the provider configuration in the user's VPN preferences;
/// - write the generated `.tun` sing-box config JSON into the shared App Group
///   container so the extension can read it (it also receives the JSON inline
///   via the start options / a provider message — belt-and-suspenders);
/// - start/stop the tunnel and reload its config while running;
/// - observe `NEVPNStatus` and surface it as a `@Published` value.
///
/// All members are MainActor-bound so `AppState` can drive it without hops.
/// The actual sing-box service runs *inside* the extension; this type never
/// spawns a subprocess and never mutates the macOS system proxy.
@MainActor
final class TunnelController: ObservableObject {
    /// Shared App Group identifier — identical to the value in both targets'
    /// entitlements. The extension reads its config from this container.
    static let appGroupIdentifier = "HC438T2B8P.group.com.gumpw.linko"
    /// Bundle id of the packet-tunnel system extension. Must match the
    /// extension target's `PRODUCT_BUNDLE_IDENTIFIER` and the
    /// `NEProviderClasses` wiring in its Info.plist.
    static let providerBundleIdentifier = "com.gumpw.linko.tunnel"
    /// Name of the config file the extension reads from the App Group container.
    static let configFileName = "config.json"

    /// Live tunnel status, mirrored from the underlying `NEVPNConnection`.
    @Published private(set) var status: NEVPNStatus = .invalid

    /// The manager backing the provider, loaded/created lazily. `nil` until the
    /// first `load()`/`install()`.
    private var manager: NETunnelProviderManager?

    /// KVO-ish status observation token for `NEVPNStatusDidChange`.
    private var statusObserver: NSObjectProtocol?

    /// Activates the packet-tunnel system extension. The provider can't load
    /// until the extension is registered + approved, so this runs before any
    /// `NETunnelProviderManager` work.
    private let extensionInstaller = SystemExtensionInstaller()

    init() {}

    // MARK: - Derived state

    /// `true` once the provider configuration is installed in preferences.
    var isInstalled: Bool { manager != nil }

    /// `true` while the tunnel is connecting/connected/reasserting — i.e. TUN
    /// mode is actively handling traffic (or in the middle of coming up).
    var isActive: Bool {
        switch status {
        case .connecting, .connected, .reasserting:
            return true
        case .invalid, .disconnected, .disconnecting:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - App Group container

    /// URL of the shared App Group container. Throws a localized error if the
    /// container is unavailable (entitlement/provisioning not in place yet).
    static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw AppError(message: "无法访问共享容器（App Group 未配置）。")
        }
        return url
    }

    /// Path of the config file inside the App Group container that the
    /// extension reads.
    static func sharedConfigURL() throws -> URL {
        try containerURL().appendingPathComponent(configFileName)
    }

    // MARK: - Loading / installing

    /// Loads any existing saved provider configuration into `manager`. Reuses
    /// the first matching manager so repeated installs don't create duplicates.
    /// Idempotent; safe to call on every launch / before start.
    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            // Prefer a manager already pointing at our provider bundle.
            let mine = managers.first { mgr in
                (mgr.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == Self.providerBundleIdentifier
            }
            let resolved = mine ?? managers.first
            if let resolved {
                bind(to: resolved)
            }
        } catch {
            // A load failure (no NE entitlement yet, MDM lock, …) leaves us
            // uninstalled; install() will surface a precise error on demand.
        }
    }

    /// Ensures a provider configuration is installed and enabled, creating one
    /// if necessary, then saving it to preferences. Assumes the system extension
    /// is already activated (see `SystemExtensionInstaller`); saving a VPN
    /// configuration alone never installs the extension.
    @discardableResult
    func install() async throws -> NETunnelProviderManager {
        if manager == nil { await load() }
        let mgr = manager ?? NETunnelProviderManager()

        let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleIdentifier
        // `serverAddress` is a required, user-visible field in the VPN list; it
        // is cosmetic for a local TUN provider.
        proto.serverAddress = "sing-box"
        // Marker so the extension can locate its config even before start
        // options arrive (it reads the App Group file at this name).
        var providerConfiguration = proto.providerConfiguration ?? [:]
        providerConfiguration["configFileName"] = Self.configFileName
        proto.providerConfiguration = providerConfiguration

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Linko"
        mgr.isEnabled = true

        do {
            try await mgr.saveToPreferences()
            // A reload after save is required: the saved object's connection
            // reference is only valid once re-fetched from preferences.
            try await mgr.loadFromPreferences()
        } catch {
            throw AppError(message: "安装 TUN 扩展配置失败：\(error.localizedDescription)")
        }
        bind(to: mgr)
        return mgr
    }

    // MARK: - Start / stop

    /// Starts the tunnel with the given `.tun` config JSON.
    ///
    /// Writes the JSON to the App Group container (so the extension can read it
    /// even before the start options arrive), installs/updates the provider
    /// configuration, then starts the VPN tunnel passing the JSON inline via
    /// `configContent` (the provider reads the option first, falling back to
    /// the file). Throws a localized error on any failure.
    func start(configJSON: String) async throws {
        // Activate + register the system extension first. On a fresh machine
        // this throws SystemExtensionError.needsApproval and shows the approval
        // prompt; the user allows it in System Settings and toggles TUN again.
        try await extensionInstaller.activate()
        try writeSharedConfig(configJSON)
        let mgr = try await install()
        guard let session = mgr.connection as? NETunnelProviderSession else {
            throw AppError(message: "TUN 扩展未就绪，无法启动。")
        }
        // A stop is asynchronous: the session lingers in `.disconnecting`
        // while the provider tears down, and `startTunnel` during that window
        // is rejected by the system ("turn off then immediately back on"
        // otherwise bricks the toggle until a mode switch resets everything).
        // Wait out the teardown briefly before starting.
        for _ in 0..<40 where session.status == .disconnecting {
            try? await Task.sleep(nanoseconds: 250 * NSEC_PER_MSEC)
        }
        do {
            try session.startTunnel(options: ["configContent": configJSON as NSString])
        } catch {
            throw AppError(message: "启动 TUN 隧道失败：\(error.localizedDescription)")
        }
    }

    /// Stops the tunnel if a manager is present. Safe to call when already
    /// stopped or uninstalled.
    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    /// Pushes a new `.tun` config to a *running* tunnel without restarting it.
    /// Writes the file, then sends the JSON as a provider message; the
    /// extension's `handleAppMessage` reloads the sing-box service in place.
    /// Throws if the tunnel is not running or the message round-trip fails.
    func reload(configJSON: String) async throws {
        try writeSharedConfig(configJSON)
        guard
            let mgr = manager,
            let session = mgr.connection as? NETunnelProviderSession,
            isActive
        else {
            throw AppError(message: "TUN 隧道未运行，无法热重载配置。")
        }
        let payload = Data(configJSON.utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try session.sendProviderMessage(payload) { response in
                    // The provider returns nil on success, or error-text Data on
                    // failure (see extension's handleAppMessage contract).
                    if let response, let text = String(data: response, encoding: .utf8),
                       !text.isEmpty {
                        continuation.resume(throwing: AppError(message: "热重载失败：\(text)"))
                    } else {
                        continuation.resume()
                    }
                }
            } catch {
                continuation.resume(throwing: AppError(message: "发送配置到 TUN 扩展失败：\(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Config file

    /// Writes the `.tun` config JSON into the App Group container for the
    /// extension to read. Throws a localized error if the container is missing.
    private func writeSharedConfig(_ configJSON: String) throws {
        let url = try Self.sharedConfigURL()
        do {
            try Data(configJSON.utf8).write(to: url, options: .atomic)
        } catch {
            throw AppError(message: "写入共享配置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Binding / status

    /// Adopts `mgr` as the active manager, wires status observation, and
    /// publishes its current status.
    private func bind(to mgr: NETunnelProviderManager) {
        manager = mgr
        observeStatus(of: mgr.connection)
        status = mgr.connection.status
    }

    /// Subscribes to `NEVPNStatusDidChange` for the given connection, replacing
    /// any previous observation.
    private func observeStatus(of connection: NEVPNConnection) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] note in
            // The notification is delivered on the main queue; resolve the
            // status to a Sendable value here (reading `.status` off the
            // notification object) so the @MainActor hop captures only the
            // enum, never the non-Sendable connection.
            let resolved = (note.object as? NEVPNConnection)?.status ?? .invalid
            Task { @MainActor [weak self] in
                self?.status = resolved
            }
        }
    }
}

extension NEVPNStatus {
    /// Chinese label for the menu/status surface.
    var linkoLabel: String {
        switch self {
        case .invalid: return "未安装"
        case .disconnected: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .reasserting: return "重连中…"
        case .disconnecting: return "断开中…"
        @unknown default: return "未知"
        }
    }
}
