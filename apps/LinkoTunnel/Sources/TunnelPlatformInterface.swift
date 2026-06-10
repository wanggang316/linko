import Foundation
import Libbox
import Network
import NetworkExtension

/// Implements the two libbox protocols the command server drives:
///
/// - `LibboxPlatformInterface`: the bridge between sing-box's `tun` inbound and
///   the NetworkExtension utun device. Its centerpiece, `openTun`, configures
///   `NEPacketTunnelNetworkSettings` from the `TunOptions` sing-box produced and
///   returns the resulting utun file descriptor for libbox's gVisor stack.
/// - `LibboxCommandServerHandler`: lifecycle/system-proxy callbacks the command
///   server routes back to the provider.
///
/// All NE interaction is funnelled through the owning `PacketTunnelProvider`.
final class TunnelPlatformInterface: NSObject {
    private unowned let provider: PacketTunnelProvider

    /// The settings most recently applied to the tunnel; kept so we can
    /// re-apply them on a DNS-cache flush.
    private var networkSettings: NEPacketTunnelNetworkSettings?

    /// The default-interface monitor libbox asks us to run; started in
    /// `startDefaultInterfaceMonitor` and cancelled in `closeDefaultInterfaceMonitor`.
    private var interfaceMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.gumpw.linko.tunnel.interface-monitor")

    init(provider: PacketTunnelProvider) {
        self.provider = provider
    }

    /// Tears down monitors and clears cached settings on stop.
    func reset() {
        interfaceMonitor?.cancel()
        interfaceMonitor = nil
        networkSettings = nil
    }
}

// MARK: - LibboxPlatformInterface

extension TunnelPlatformInterface: LibboxPlatformInterfaceProtocol {
    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in
            try await openTun0(options, ret0_: ret0_)
        }
    }

    private func openTun0(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let options, let ret0_ else {
            throw tunnelError("openTun called with nil options or return pointer")
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        var hasDefaultRoute = false

        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            // DNS — OUR libbox returns a single comma-separated StringBox, not an
            // iterator. Split it back into individual server addresses.
            let dnsBox = try options.getDNSServerAddress()
            let dnsServers = dnsBox.value
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let dnsSettings: NEDNSSettings? = dnsServers.isEmpty ? nil : NEDNSSettings(servers: dnsServers)

            // IPv4 addresses + routes.
            if let ipv4 = buildIPv4Settings(options: options, hasDefaultRoute: &hasDefaultRoute) {
                settings.ipv4Settings = ipv4
            }

            // IPv6 addresses + routes (skipped cleanly when the config is IPv4-only).
            if let ipv6 = buildIPv6Settings(options: options, hasDefaultRoute: &hasDefaultRoute) {
                settings.ipv6Settings = ipv6
            }

            if let dnsSettings {
                // When the tunnel does not capture the default route, the DNS
                // servers may sit outside the routed ranges; force-match all
                // domains so name resolution still flows through the tunnel.
                if !hasDefaultRoute {
                    dnsSettings.matchDomains = [""]
                    dnsSettings.matchDomainsNoSearch = true
                }
                settings.dnsSettings = dnsSettings
            }
        }

        // Optional HTTP proxy advertisement (disabled for pure TUN global mode,
        // kept for completeness).
        if options.isHTTPProxyEnabled() {
            let proxySettings = NEProxySettings()
            let server = NEProxyServer(
                address: options.getHTTPProxyServer(),
                port: Int(options.getHTTPProxyServerPort())
            )
            proxySettings.httpEnabled = true
            proxySettings.httpServer = server
            proxySettings.httpsEnabled = true
            proxySettings.httpsServer = server
            proxySettings.exceptionList = collectStrings(options.getHTTPProxyBypassDomain())
            let matchDomains = collectStrings(options.getHTTPProxyMatchDomain())
            if !matchDomains.isEmpty {
                proxySettings.matchDomains = matchDomains
            }
            settings.proxySettings = proxySettings
        }

        self.networkSettings = settings
        // Allocating the utun interface; the fd becomes readable afterwards.
        try await provider.setTunnelNetworkSettings(settings)

        // Resolve the utun file descriptor. Prefer reading it straight off the
        // packet flow via KVC; fall back to libbox's own lookup.
        if let fd = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            return
        }
        let looped = LibboxGetTunnelFileDescriptor()
        if looped != -1 {
            ret0_.pointee = looped
        } else {
            throw tunnelError("Missing tunnel file descriptor")
        }
    }

    private func buildIPv4Settings(
        options: LibboxTunOptionsProtocol,
        hasDefaultRoute: inout Bool
    ) -> NEIPv4Settings? {
        var addresses: [String] = []
        var masks: [String] = []
        if let iterator = options.getInet4Address() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { break }
                addresses.append(prefix.address())
                masks.append(prefix.mask())
            }
        }
        guard !addresses.isEmpty else { return nil }

        let ipv4 = NEIPv4Settings(addresses: addresses, subnetMasks: masks)

        var routes: [NEIPv4Route] = []
        if let iterator = options.getInet4RouteAddress() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { break }
                routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
            }
        }
        if routes.isEmpty {
            // No explicit routes → capture everything (TUN global mode).
            ipv4.includedRoutes = [NEIPv4Route.default()]
            hasDefaultRoute = true
        } else {
            ipv4.includedRoutes = routes
        }

        var excludedRoutes: [NEIPv4Route] = []
        if let iterator = options.getInet4RouteExcludeAddress() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { break }
                excludedRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
            }
        }
        if !excludedRoutes.isEmpty {
            ipv4.excludedRoutes = excludedRoutes
        }

        return ipv4
    }

    private func buildIPv6Settings(
        options: LibboxTunOptionsProtocol,
        hasDefaultRoute: inout Bool
    ) -> NEIPv6Settings? {
        var addresses: [String] = []
        var prefixLengths: [NSNumber] = []
        if let iterator = options.getInet6Address() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { break }
                addresses.append(prefix.address())
                prefixLengths.append(NSNumber(value: prefix.prefix()))
            }
        }
        guard !addresses.isEmpty else { return nil }

        let ipv6 = NEIPv6Settings(addresses: addresses, networkPrefixLengths: prefixLengths)

        var routes: [NEIPv6Route] = []
        if let iterator = options.getInet6RouteAddress() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { break }
                routes.append(NEIPv6Route(
                    destinationAddress: prefix.address(),
                    networkPrefixLength: NSNumber(value: prefix.prefix())
                ))
            }
        }
        if routes.isEmpty {
            ipv6.includedRoutes = [NEIPv6Route.default()]
            hasDefaultRoute = true
        } else {
            ipv6.includedRoutes = routes
        }

        var excludedRoutes: [NEIPv6Route] = []
        if let iterator = options.getInet6RouteExcludeAddress() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { break }
                excludedRoutes.append(NEIPv6Route(
                    destinationAddress: prefix.address(),
                    networkPrefixLength: NSNumber(value: prefix.prefix())
                ))
            }
        }
        if !excludedRoutes.isEmpty {
            ipv6.excludedRoutes = excludedRoutes
        }

        return ipv6
    }

    func autoDetectControl(_ fd: Int32) throws {
        // No-op: NetworkExtension binds sockets to the physical interface for us.
    }

    func usePlatformAutoDetectControl() -> Bool { false }

    func useProcFS() -> Bool { false }

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool { false }

    func clearDNSCache() {
        guard let networkSettings else { return }
        provider.reasserting = true
        // Re-apply the current settings to flush the resolver cache.
        try? runBlocking { [self] in
            try await provider.setTunnelNetworkSettings(nil)
            try await provider.setTunnelNetworkSettings(networkSettings)
        }
        provider.reasserting = false
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let monitor = interfaceMonitor else {
            throw tunnelError("Default interface monitor not started")
        }
        let path = monitor.currentPath
        let interfaces: [LibboxNetworkInterface] = path.availableInterfaces.map { nwInterface in
            let boxInterface = LibboxNetworkInterface()
            boxInterface.name = nwInterface.name
            boxInterface.index = Int32(nwInterface.index)
            boxInterface.type = nwInterface.type.libboxType
            return boxInterface
        }
        return NetworkInterfaceIterator(interfaces: interfaces)
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else {
            throw tunnelError("startDefaultInterfaceMonitor called with nil listener")
        }
        let monitor = NWPathMonitor()
        self.interfaceMonitor = monitor

        // Block until the first path is known so libbox sees a valid default
        // interface immediately after this call returns. The path handler runs
        // on a concurrent queue; the relay box guards its one-shot signal and
        // smuggles the non-Sendable listener across the boundary (it is only
        // ever touched on the monitor queue).
        let semaphore = DispatchSemaphore(value: 0)
        let relay = InterfaceUpdateRelay(listener: listener) { semaphore.signal() }
        monitor.pathUpdateHandler = { path in
            relay.deliver(path)
        }
        monitor.start(queue: monitorQueue)
        semaphore.wait()
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        interfaceMonitor?.cancel()
        interfaceMonitor = nil
    }

    func findConnectionOwner(
        _ ipProtocol: Int32,
        sourceAddress: String?,
        sourcePort: Int32,
        destinationAddress: String?,
        destinationPort: Int32
    ) throws -> LibboxConnectionOwner {
        // Process matching needs a privileged helper on macOS; our config never
        // sets `needFindProcess`, so this is never reached.
        throw tunnelError("findConnectionOwner not implemented")
    }

    func readWIFIState() -> LibboxWIFIState? {
        // Skipped to avoid the CoreWLAN entitlement; not needed for routing.
        nil
    }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    func send(_ notification: LibboxNotification?) throws {
        // No user-facing notifications from the extension for M2.
    }
}

// MARK: - LibboxCommandServerHandler

extension TunnelPlatformInterface: LibboxCommandServerHandlerProtocol {
    func serviceStop() throws {
        provider.stopServiceFromCommand()
    }

    func serviceReload() throws {
        try runBlocking { [self] in
            try await provider.reloadService()
        }
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        if let proxySettings = networkSettings?.proxySettings {
            status.available = true
            status.enabled = proxySettings.httpEnabled || proxySettings.httpsEnabled
        }
        return status
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        guard let networkSettings, let proxySettings = networkSettings.proxySettings else { return }
        proxySettings.httpEnabled = isEnabled
        proxySettings.httpsEnabled = isEnabled
        try runBlocking { [self] in
            try await provider.setTunnelNetworkSettings(networkSettings)
        }
    }

    func writeDebugMessage(_ message: String?) {
        if let message {
            NSLog("[LinkoTunnel] %@", message)
        }
    }
}

// MARK: - Helpers

private extension TunnelPlatformInterface {
    func tunnelError(_ message: String) -> NSError {
        NSError(domain: "LinkoTunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func collectStrings(_ iterator: LibboxStringIteratorProtocol?) -> [String] {
        guard let iterator else { return [] }
        var result: [String] = []
        while iterator.hasNext() {
            result.append(iterator.next())
        }
        return result
    }
}
