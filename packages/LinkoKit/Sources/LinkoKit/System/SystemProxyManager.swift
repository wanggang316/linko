import Foundation

/// Errors thrown while toggling the macOS system proxy.
public enum SystemProxyError: Error, Equatable, LocalizedError {
    case commandFailed(arguments: [String], exitCode: Int32, stderr: String)
    case noEnabledNetworkServices

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(arguments, exitCode, stderr):
            let detail = stderr.isEmpty ? "" : ": \(stderr)"
            return "networksetup \(arguments.joined(separator: " ")) failed (exit \(exitCode))\(detail)"
        case .noEnabledNetworkServices:
            return "No enabled network services were found."
        }
    }
}

/// Toggles the macOS system proxy (web, secure web, SOCKS) on all enabled
/// network services via `/usr/sbin/networksetup`, remembering the previous
/// proxy state so `disable()` can restore it.
///
/// The pre-enable snapshot is also persisted to disk *before* any mutation,
/// so a crash or force-quit while the proxy is enabled can be recovered on
/// the next launch via `restorePersistedSnapshotIfPresent()`.
public final class SystemProxyManager: SystemProxyRunning, @unchecked Sendable {
    /// The three proxy kinds linko manages, with their networksetup verbs.
    private enum ProxyKind: String, CaseIterable, Codable {
        case web
        case secureWeb
        case socks

        var getCommand: String {
            switch self {
            case .web: return "-getwebproxy"
            case .secureWeb: return "-getsecurewebproxy"
            case .socks: return "-getsocksfirewallproxy"
            }
        }

        var setCommand: String {
            switch self {
            case .web: return "-setwebproxy"
            case .secureWeb: return "-setsecurewebproxy"
            case .socks: return "-setsocksfirewallproxy"
            }
        }

        var setStateCommand: String {
            switch self {
            case .web: return "-setwebproxystate"
            case .secureWeb: return "-setsecurewebproxystate"
            case .socks: return "-setsocksfirewallproxystate"
            }
        }
    }

    /// Proxy settings of one kind on one service, captured before `enable`.
    private struct ProxySnapshot: Codable {
        let service: String
        let kind: ProxyKind
        let wasEnabled: Bool
        let server: String?
        let port: Int?

        /// A snapshot representing "this proxy kind was off".
        static func off(service: String, kind: ProxyKind) -> ProxySnapshot {
            ProxySnapshot(service: service, kind: kind, wasEnabled: false, server: nil, port: nil)
        }
    }

    private static let networksetupPath = "/usr/sbin/networksetup"

    private static func defaultSnapshotFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linko", isDirectory: true)
            .appendingPathComponent("system-proxy-snapshot.json")
    }

    private let shell: ShellRunning
    private let snapshotFileURL: URL
    private let lock = NSLock()
    private var snapshots: [ProxySnapshot] = []
    private var enabled = false

    public init(shell: ShellRunning = ProcessShellRunner(), snapshotFileURL: URL? = nil) {
        self.shell = shell
        self.snapshotFileURL = snapshotFileURL ?? Self.defaultSnapshotFileURL()
    }

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    public func enable(host: String, port: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        let services = try enabledNetworkServices()
        guard !services.isEmpty else {
            throw SystemProxyError.noEnabledNetworkServices
        }

        if !enabled {
            var captured: [ProxySnapshot] = []
            for service in services {
                for kind in ProxyKind.allCases {
                    var snap = try snapshot(service: service, kind: kind)
                    // A leftover linko entry (crashed previous session) must
                    // never be "restored" later; treat it as previously off.
                    if snap.wasEnabled, snap.server == host, snap.port == port {
                        snap = .off(service: service, kind: kind)
                    }
                    captured.append(snap)
                }
            }
            // Persist and store the snapshot *before* mutating anything, so a
            // crash mid-enable (or on a later force-quit) stays recoverable.
            try persistSnapshots(captured)
            snapshots = captured
        }
        // When already enabled (e.g. port change), keep the original
        // pre-linko snapshot: re-snapshotting now would capture our own
        // 127.0.0.1 settings and poison the restore path.

        do {
            for service in services {
                for kind in ProxyKind.allCases {
                    try runChecked([kind.setCommand, service, host, String(port)])
                }
            }
        } catch {
            if !enabled {
                // Roll back the services that were already repointed, then
                // surface the original error.
                restoreBestEffort(snapshots)
                snapshots = []
                removeSnapshotFile()
            }
            throw error
        }
        enabled = true
    }

    public func disable() throws {
        lock.lock()
        defer { lock.unlock() }

        // Restore every snapshot even if one fails, so a single bad service
        // cannot leave the rest pointed at a dead local proxy.
        let firstError = restoreBestEffort(snapshots)
        snapshots = []
        enabled = false
        removeSnapshotFile()
        if let firstError {
            throw firstError
        }
    }

    @discardableResult
    public func restorePersistedSnapshotIfPresent() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !enabled else { return false }
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path) else { return false }
        guard
            let data = try? Data(contentsOf: snapshotFileURL),
            let persisted = try? JSONDecoder().decode([ProxySnapshot].self, from: data)
        else {
            // Unreadable/corrupt snapshot: drop it rather than retry forever.
            removeSnapshotFile()
            return false
        }

        let firstError = restoreBestEffort(persisted)
        removeSnapshotFile()
        if let firstError {
            throw firstError
        }
        return true
    }

    // MARK: - networksetup plumbing

    /// Parses `networksetup -listallnetworkservices`, dropping the
    /// explanatory header line and `*`-prefixed (disabled) services.
    private func enabledNetworkServices() throws -> [String] {
        let result = try runChecked(["-listallnetworkservices"])
        return result.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !$0.contains("asterisk") }
            .filter { !$0.hasPrefix("*") }
    }

    private func snapshot(service: String, kind: ProxyKind) throws -> ProxySnapshot {
        let result = try runChecked([kind.getCommand, service])
        var wasEnabled = false
        var server: String?
        var port: Int?

        for line in result.standardOutput.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Enabled":
                wasEnabled = (value == "Yes")
            case "Server":
                server = value.isEmpty ? nil : value
            case "Port":
                port = Int(value).flatMap { $0 > 0 ? $0 : nil }
            default:
                break
            }
        }

        return ProxySnapshot(
            service: service,
            kind: kind,
            wasEnabled: wasEnabled,
            server: server,
            port: port
        )
    }

    private func restore(_ snapshot: ProxySnapshot) throws {
        if snapshot.wasEnabled, let server = snapshot.server, let port = snapshot.port {
            try runChecked([snapshot.kind.setCommand, snapshot.service, server, String(port)])
        } else {
            try runChecked([snapshot.kind.setStateCommand, snapshot.service, "off"])
        }
    }

    /// Restores all snapshots, continuing past failures; returns the first
    /// error encountered, if any.
    @discardableResult
    private func restoreBestEffort(_ snapshots: [ProxySnapshot]) -> Error? {
        var firstError: Error?
        for snapshot in snapshots {
            do {
                try restore(snapshot)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        return firstError
    }

    // MARK: - Snapshot persistence

    private func persistSnapshots(_ snapshots: [ProxySnapshot]) throws {
        try FileManager.default.createDirectory(
            at: snapshotFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshots)
        try data.write(to: snapshotFileURL, options: .atomic)
    }

    private func removeSnapshotFile() {
        try? FileManager.default.removeItem(at: snapshotFileURL)
    }

    @discardableResult
    private func runChecked(_ arguments: [String]) throws -> ShellResult {
        let result = try shell.run(
            executablePath: Self.networksetupPath,
            arguments: arguments
        )
        guard result.exitCode == 0 else {
            throw SystemProxyError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                stderr: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }
}
