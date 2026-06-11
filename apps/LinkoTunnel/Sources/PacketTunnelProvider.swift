import Foundation
import Libbox
@preconcurrency import NetworkExtension

/// The NetworkExtension packet-tunnel provider that runs sing-box (1.13.13 via
/// libbox) in TUN global mode inside the `com.gumpw.linko.tunnel` system
/// extension.
///
/// Lifecycle (libbox 1.13 has no separate BoxService — the running instance
/// lives inside the command server):
///   `LibboxSetup` → `LibboxNewCommandServer` → `commandServer.start()` →
///   `commandServer.startOrReloadService(config)` → libbox calls back into the
///   platform interface's `openTun`, which configures the utun and returns its fd.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    /// Shared App Group identifier; the main app writes the config here and the
    /// provider reads libbox's working/temp/base paths out of the same container.
    /// Must be the TeamID-prefixed form from BOTH targets' entitlements — an
    /// unentitled identifier silently resolves to a private per-user container,
    /// so the provider would never see the config the app wrote.
    private static let appGroupIdentifier = "HC438T2B8P.group.com.gumpw.linko"
    private static let configFileName = "config.json"

    private var commandServer: LibboxCommandServer?
    private var platformInterface: TunnelPlatformInterface?

    /// The most recently applied config JSON, retained for reloads.
    private var currentConfig: String?

    // MARK: - Start

    /// Completion-handler form (not the `async` override) so the non-Sendable
    /// `options` dictionary does not cross an isolation boundary under Swift 6
    /// strict concurrency. Every step below is synchronous — libbox parses the
    /// config and brings the box up on its own threads — so no `Task` is needed.
    override func startTunnel(
        options startOptions: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try startTunnelSynchronously(options: startOptions)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    private func startTunnelSynchronously(options startOptions: [String: NSObject]?) throws {
        guard let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
        else {
            throw providerError("App Group container unavailable: \(Self.appGroupIdentifier)")
        }

        let basePath = groupURL.path
        let workingURL = groupURL.appendingPathComponent("Working", isDirectory: true)
        let tempURL = groupURL.appendingPathComponent("Temp", isDirectory: true)
        try FileManager.default.createDirectory(at: workingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)

        // Config source: the start option wins (belt), otherwise the App Group
        // file the main app wrote (suspenders).
        let configContent: String
        if let optionConfig = startOptions?["configContent"] as? String, !optionConfig.isEmpty {
            configContent = optionConfig
        } else {
            let configURL = groupURL.appendingPathComponent(Self.configFileName)
            guard let fileConfig = try? String(contentsOf: configURL, encoding: .utf8), !fileConfig.isEmpty else {
                throw providerError("No sing-box config provided (neither option nor App Group file)")
            }
            configContent = fileConfig
        }
        self.currentConfig = configContent

        // 1. libbox setup — only the fields our header exposes.
        let setup = LibboxSetupOptions()
        setup.basePath = basePath
        setup.workingPath = workingURL.path
        setup.tempPath = tempURL.path
        setup.logMaxLines = 3000
        setup.debug = false
        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError {
            throw setupError
        }
        LibboxSetLocale("en")
        LibboxSetMemoryLimit(true)

        // 2. Platform interface doubles as the command-server handler.
        let platform = TunnelPlatformInterface(provider: self)
        self.platformInterface = platform

        var serverError: NSError?
        guard let server = LibboxNewCommandServer(platform, platform, &serverError) else {
            throw serverError ?? providerError("Failed to create command server")
        }
        self.commandServer = server

        // 3. Open the command server's control socket (does not start sing-box).
        try server.start()

        // 4. Parse the config, build the box instance, and run it. libbox calls
        //    back into platform.openTun on its own thread to bring up the utun.
        let override = LibboxOverrideOptions()
        try server.startOrReloadService(configContent, options: override)

        server.writeMessage(2, message: "started")
    }

    // MARK: - Stop

    override func stopTunnel(with reason: NEProviderStopReason) async {
        commandServer?.writeMessage(2, message: "stopping")
        do {
            try commandServer?.closeService()
        } catch {
            NSLog("[LinkoTunnel] closeService failed: %@", error.localizedDescription)
        }
        platformInterface?.reset()
        try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
        commandServer?.close()
        commandServer = nil
        platformInterface = nil
    }

    // MARK: - Messages / reload

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let newConfig = String(data: messageData, encoding: .utf8), !newConfig.isEmpty else {
            return Data("invalid config message".utf8)
        }
        do {
            try persistConfig(newConfig)
            self.currentConfig = newConfig
            reasserting = true
            defer { reasserting = false }
            try commandServer?.startOrReloadService(newConfig, options: LibboxOverrideOptions())
            return nil
        } catch {
            return Data("reload failed: \(error.localizedDescription)".utf8)
        }
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }

    // MARK: - Command-server callbacks (invoked from TunnelPlatformInterface)

    /// Routed from `LibboxCommandServerHandler.serviceStop`: libbox asked the
    /// tunnel to stop. Cancel the NE tunnel, which drives `stopTunnel`.
    func stopServiceFromCommand() {
        cancelTunnelWithError(nil)
    }

    /// Routed from `LibboxCommandServerHandler.serviceReload`: re-parse and
    /// re-run the current config without tearing down the tunnel.
    func reloadService() async throws {
        guard let config = currentConfig else {
            throw providerError("No config to reload")
        }
        reasserting = true
        defer { reasserting = false }
        try commandServer?.startOrReloadService(config, options: LibboxOverrideOptions())
    }

    // MARK: - Helpers

    private func persistConfig(_ config: String) throws {
        guard let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
        else {
            throw providerError("App Group container unavailable for config persistence")
        }
        let configURL = groupURL.appendingPathComponent(Self.configFileName)
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func providerError(_ message: String) -> NSError {
        NSError(domain: "LinkoTunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
