import AppKit
import LinkoKit
import SwiftUI

/// Identifiers for auxiliary windows opened from the menu bar.
enum WindowID {
    static let importSubscription = "import-subscription"
}

@main
struct LinkoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appState)
        } label: {
            Image(systemName: menuBarSymbolName)
        }
        .menuBarExtraStyle(.menu)

        Window("导入订阅", id: WindowID.importSubscription) {
            ImportSubscriptionView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    private var menuBarSymbolName: String {
        switch appState.coreState {
        case .running:
            return "bolt.horizontal.circle.fill"
        case .stopped:
            return "bolt.horizontal.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }
}
