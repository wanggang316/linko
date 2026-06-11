import Foundation
import LinkoKit
import Network

/// Watches the active network path and emits a `NetworkSnapshot` (interface kind
/// + local IPv4 addresses) whenever it changes. Drives network-based profile
/// auto-switching.
///
/// Both signals are **permission-free**: `NWPathMonitor` reports the interface
/// type and change events without entitlements, and `getifaddrs` reads local
/// IPv4 addresses without any prompt — unlike the Wi-Fi SSID, which since macOS
/// 10.15 requires Location authorization. Matching on subnet/interface gives the
/// Surge `SUBNET` behavior with zero friction.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.gumpw.linko.network-monitor")

    /// Invoked on the main actor whenever the snapshot changes (deduplicated).
    var onChange: ((NetworkSnapshot) -> Void)?

    /// The most recent snapshot, or `nil` before the first path update.
    private(set) var current: NetworkSnapshot?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Runs on `queue`. Reduce the (non-Sendable) NWPath to a Sendable
            // snapshot here, then hand only that across to the main actor.
            let snapshot = NetworkMonitor.snapshot(from: path)
            Task { @MainActor [weak self] in
                self?.deliver(snapshot)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private func deliver(_ snapshot: NetworkSnapshot) {
        guard current != snapshot else { return }
        current = snapshot
        onChange?(snapshot)
    }

    // MARK: - Path → snapshot (pure)

    nonisolated private static func snapshot(from path: NWPath) -> NetworkSnapshot {
        let kind: NetworkInterfaceKind
        if path.usesInterfaceType(.wifi) {
            kind = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = .wired
        } else if path.usesInterfaceType(.cellular) {
            kind = .cellular
        } else {
            kind = .other
        }
        return NetworkSnapshot(interface: kind, ipv4Addresses: localIPv4Addresses())
    }

    /// Active, non-loopback IPv4 addresses via `getifaddrs` (permission-free).
    nonisolated static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            if result == 0 {
                let value = String(cString: host)
                if !value.isEmpty { addresses.append(value) }
            }
        }
        return addresses
    }
}
