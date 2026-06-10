import Foundation
import NetworkExtension

// Entry point for the packet-tunnel system extension. `startSystemExtensionMode`
// registers the provider classes declared in Info.plist's `NEProviderClasses`
// (here `LinkoTunnel.PacketTunnelProvider`) and hands control to the
// NetworkExtension runtime, which instantiates the provider on demand.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
