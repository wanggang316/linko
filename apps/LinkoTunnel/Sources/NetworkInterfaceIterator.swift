import Foundation
import Libbox
import Network

/// Adapts a fixed array of `LibboxNetworkInterface` into the iterator protocol
/// libbox expects back from `getInterfaces`. libbox drains it with the
/// `hasNext` / `next` pair.
final class NetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var interfaces: [LibboxNetworkInterface]
    private var index = 0

    init(interfaces: [LibboxNetworkInterface]) {
        self.interfaces = interfaces
    }

    func hasNext() -> Bool {
        index < interfaces.count
    }

    func next() -> LibboxNetworkInterface? {
        guard index < interfaces.count else { return nil }
        defer { index += 1 }
        return interfaces[index]
    }
}

/// Relays `NWPath` updates to libbox's interface-update listener and fires a
/// one-shot "first path known" callback. Lives behind `@unchecked Sendable`
/// because the `NWPathMonitor` invokes `deliver` on a serial-per-monitor queue
/// and the one-shot flag is lock-guarded; the libbox listener is only ever
/// touched from that queue.
final class InterfaceUpdateRelay: @unchecked Sendable {
    private let listener: LibboxInterfaceUpdateListenerProtocol
    private let onPhysicalInterface: (NWInterface?) -> Void
    private let onFirstPath: () -> Void
    private let lock = NSLock()
    private var firstPathDelivered = false
    private var lastReported: String?

    init(
        listener: LibboxInterfaceUpdateListenerProtocol,
        onPhysicalInterface: @escaping (NWInterface?) -> Void,
        onFirstPath: @escaping () -> Void
    ) {
        self.listener = listener
        self.onPhysicalInterface = onPhysicalInterface
        self.onFirstPath = onFirstPath
    }

    func deliver(_ path: NWPath) {
        // Report only a physical interface: the extension's own utun can be
        // listed in the path. Index -1 tells libbox the network is gone, so it
        // drops the stale default interface and resets connections on return.
        let physical = path.status == .unsatisfied ? nil : path.physicalInterface
        onPhysicalInterface(physical)
        listener.updateDefaultInterface(
            physical?.name ?? "",
            interfaceIndex: physical.map { Int32($0.index) } ?? -1,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
        let report = "\(path.status) \(physical.map { "\($0.name)#\($0.index)" } ?? "none")"
        lock.lock()
        let shouldSignal = !firstPathDelivered
        firstPathDelivered = true
        let changed = report != lastReported
        lastReported = report
        lock.unlock()
        if changed {
            tunnelLog.error("default interface: \(report, privacy: .public)")
        }
        if shouldSignal {
            onFirstPath()
        }
    }
}

extension NWPath {
    /// The first available interface that leaves the host directly: never a
    /// tunnel (utun, ipsec) or loopback, which would loop traffic back into
    /// the tunnel.
    var physicalInterface: NWInterface? {
        availableInterfaces.first { iface in
            iface.type != .loopback && !iface.name.hasPrefix("lo")
                && !iface.name.hasPrefix("utun") && !iface.name.hasPrefix("ipsec")
        }
    }
}

extension NWInterface.InterfaceType {
    /// Maps a Network framework interface type to the libbox enum constant.
    var libboxType: Int32 {
        switch self {
        case .wifi:
            return LibboxInterfaceTypeWIFI
        case .cellular:
            return LibboxInterfaceTypeCellular
        case .wiredEthernet:
            return LibboxInterfaceTypeEthernet
        default:
            return LibboxInterfaceTypeOther
        }
    }
}
