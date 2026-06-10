import AppKit

/// Application delegate that bounds the system-proxy lifecycle: at launch it
/// recovers settings left behind by a crashed/force-quit previous session,
/// and at termination it restores the system proxy and stops the core.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.recoverFromPreviousSession()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
}
