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
    private let onFirstPath: () -> Void
    private let lock = NSLock()
    private var firstPathDelivered = false

    init(listener: LibboxInterfaceUpdateListenerProtocol, onFirstPath: @escaping () -> Void) {
        self.listener = listener
        self.onFirstPath = onFirstPath
    }

    func deliver(_ path: NWPath) {
        let defaultInterface = path.availableInterfaces.first
        listener.updateDefaultInterface(
            defaultInterface?.name ?? "",
            interfaceIndex: Int32(defaultInterface?.index ?? 0),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
        lock.lock()
        let shouldSignal = !firstPathDelivered
        firstPathDelivered = true
        lock.unlock()
        if shouldSignal {
            onFirstPath()
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
