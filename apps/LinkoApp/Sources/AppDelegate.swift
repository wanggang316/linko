import AppKit
import LinkoKit

/// Application delegate that bounds the system-proxy lifecycle: at launch it
/// recovers settings left behind by a crashed/force-quit previous session,
/// and at termination it restores the system proxy and stops the core. It also
/// handles incoming `linko://` URLs (the app's automation scheme).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register for `linko://` URLs. The Apple Event handler is the reliable
        // path for an `LSUIElement` menu-bar app — it fires for URLs opened
        // before and after launch, where `application(_:open:)` can be missed.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.recoverFromPreviousSession()
        // Resume the previous session's proxy on/off state, so a relaunch
        // (manual or at login) picks up where the user left off. Runs after
        // recovery so a leftover system-proxy snapshot is cleared first.
        Task { await AppState.shared.restorePreviousProxyState() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }

    /// Decodes the `linko://…` URL carried by the Get-URL Apple Event and
    /// dispatches it onto `AppState`. Unrecognized URLs are ignored.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard
            let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
            let url = URL(string: string),
            let command = LinkoURLScheme.command(from: url)
        else { return }
        Task { await AppState.shared.handle(command: command) }
    }
}
