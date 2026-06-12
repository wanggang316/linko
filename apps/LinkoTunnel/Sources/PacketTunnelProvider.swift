import Foundation
import Libbox
@preconcurrency import NetworkExtension
import os

/// Diagnostics logger. Uses `.error` level so entries persist in the unified
/// log without enabling private/info capture (`log show --predicate
/// 'subsystem == "com.gumpw.linko.tunnel"'`).
let tunnelLog = Logger(subsystem: "com.gumpw.linko.tunnel", category: "provider")

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
        tunnelLog.error("startTunnel: begin")
        let configContent: String
        do {
            // Cheap, non-blocking setup: dirs, LibboxSetup, command server + its
            // control socket. Sets currentConfig.
            configContent = try setUpService(options: startOptions)
        } catch {
            tunnelLog.error("startTunnel: setup FAILED: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
            return
        }

        // Return to NE now, BEFORE bringing the box up. startOrReloadService
        // blocks until libbox's openTun returns, and openTun applies the tunnel
        // network settings whose completion NE delivers back on THIS (the NE
        // start) thread — running it here would deadlock and the session would
        // hang in "connecting" forever. NE reaches "connected" once openTun
        // applies the settings from the background box-up below.
        tunnelLog.error("startTunnel: setup ok, returning; bringing box up in background")
        completionHandler(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let server = self.commandServer else { return }
            do {
                tunnelLog.error("startOrReloadService: begin (background)")
                try server.startOrReloadService(configContent, options: LibboxOverrideOptions())
                tunnelLog.error("startOrReloadService: done")
                server.writeMessage(2, message: "started")
            } catch {
                tunnelLog.error("startOrReloadService FAILED: \(error.localizedDescription, privacy: .public)")
                self.cancelTunnelWithError(error)
            }
        }
    }

    /// Non-blocking setup: working dirs, LibboxSetup, command server + control
    /// socket. Returns the resolved config (also stored in `currentConfig`).
    /// Does NOT start the box — that blocks and must run off the NE thread.
    @discardableResult
    private func setUpService(options startOptions: [String: NSObject]?) throws -> String {
        // A system extension runs as root and CANNOT use the per-user App Group
        // container (`containerURL` returns nil for it, and even when it doesn't
        // root's container is a different directory than the app's). So libbox's
        // working dirs live in the extension's own root-writable Application
        // Support directory, and the config is exchanged over IPC (start options
        // / provider messages) rather than a shared file — persisted privately
        // so a system-initiated relaunch (on-demand / at boot) can recover it.
        let baseURL = try Self.workingBaseDirectory()
        let basePath = baseURL.path
        let workingURL = baseURL.appendingPathComponent("Working", isDirectory: true)
        let tempURL = baseURL.appendingPathComponent("Temp", isDirectory: true)
        try FileManager.default.createDirectory(at: workingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)

        // Config source: the inline start option wins; otherwise the copy we
        // persisted on a previous start (covers a relaunch with no options).
        let configContent: String
        if let optionConfig = startOptions?["configContent"] as? String, !optionConfig.isEmpty {
            configContent = optionConfig
            try? persistConfig(optionConfig)
        } else if let saved = try? String(
            contentsOf: baseURL.appendingPathComponent(Self.configFileName), encoding: .utf8
        ), !saved.isEmpty {
            configContent = saved
        } else {
            throw providerError("No sing-box config provided (no start option and no saved config)")
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
        tunnelLog.error("setup done, starting command server")
        try server.start()

        // The box itself (startOrReloadService) is started by the caller on a
        // background thread — see startTunnel — because it blocks on openTun.
        return configContent
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

    /// The extension's private, root-writable working directory. The App Group
    /// container is unavailable to a root-run system extension, so libbox's
    /// base/working/temp dirs and the persisted config live here instead.
    private static func workingBaseDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = support.appendingPathComponent("LinkoTunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func persistConfig(_ config: String) throws {
        let configURL = try Self.workingBaseDirectory().appendingPathComponent(Self.configFileName)
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func providerError(_ message: String) -> NSError {
        NSError(domain: "LinkoTunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
