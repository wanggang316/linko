import Foundation
import SystemExtensions

/// Activates the `LinkoTunnel` packet-tunnel **system extension** via the
/// SystemExtensions framework.
///
/// This is the step that produces the one-time "Linko 想要添加系统扩展" prompt and
/// registers the extension with `sysextd`. It must run BEFORE any
/// `NETunnelProviderManager` work — saving a VPN configuration does NOT install
/// or activate a system extension, so without this the provider can never load
/// and no approval prompt ever appears.
///
/// On a fresh machine the OS reports `requestNeedsUserApproval`: the extension
/// is pending until the user clicks "允许" in System Settings → Privacy &
/// Security. We surface that as a localized error so the caller can tell the
/// user what to do; the next activation attempt (after approval) finishes
/// immediately.
@MainActor
final class SystemExtensionInstaller: NSObject {
    /// Bundle id of the system extension; matches the LinkoTunnel target.
    static let identifier = "com.gumpw.linko.tunnel"

    /// `true` once an activation request has reported `.completed` this launch,
    /// so repeated TUN starts don't re-submit a request every time.
    private(set) var isActivated = false

    private var continuation: CheckedContinuation<Void, Error>?

    /// Submits an activation request and awaits its outcome. Resolves when the
    /// extension is active; throws `SystemExtensionError.needsApproval` while it
    /// is awaiting the user's approval in System Settings, or a wrapped OS error
    /// on failure.
    func activate() async throws {
        if isActivated { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: Self.identifier,
                queue: .main
            )
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func resume(_ result: Result<Void, Error>) {
        let cont = continuation
        continuation = nil
        switch result {
        case .success:
            cont?.resume()
        case let .failure(error):
            cont?.resume(throwing: error)
        }
    }
}

/// Errors specific to system-extension activation.
enum SystemExtensionError: LocalizedError {
    /// The extension is installed but waiting for the user to approve it in
    /// System Settings → Privacy & Security.
    case needsApproval

    var errorDescription: String? {
        switch self {
        case .needsApproval:
            return "需在「系统设置 → 隐私与安全性」中点击「允许」以加载 Linko 的系统扩展，然后重新打开 TUN 开关。"
        }
    }
}

extension SystemExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always adopt the version bundled in the running app (handles upgrades).
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // The "添加系统扩展" prompt is now showing; activation pauses until the
        // user approves. Surface a clear instruction and stop here.
        Task { @MainActor in self.resume(.failure(SystemExtensionError.needsApproval)) }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            self.isActivated = true
            self.resume(.success(()))
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.resume(.failure(error)) }
    }
}
