import AppKit
import LinkoKit
import SwiftUI

/// Identifiers for auxiliary windows opened from the menu bar.
enum WindowID {
    static let importSubscription = "import-subscription"
    static let dashboard = "dashboard"
}

@main
struct LinkoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared
    /// Backs the Dashboard window's observability streams. Owned here so it
    /// survives window open/close cycles and stays bound to the shared state.
    @StateObject private var dashboardViewModel = DashboardViewModel(appState: AppState.shared)

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appState)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Window("仪表盘", id: WindowID.dashboard) {
            DashboardView()
                .environmentObject(appState)
                .environmentObject(dashboardViewModel)
                .frame(minWidth: 820, idealWidth: 900, minHeight: 540, idealHeight: 600)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        Window("导入订阅", id: WindowID.importSubscription) {
            ImportSubscriptionView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
    }

    /// The menu-bar glyph. The brand smiley (a template image, so the system
    /// tints it for light/dark/highlight) marks the normal states — full when
    /// the core is running, dimmed when stopped — while a failure falls back to
    /// the universal warning triangle so an error stays unmistakable.
    @ViewBuilder
    private var menuBarLabel: some View {
        switch appState.coreState {
        case .running:
            Image("MenuBarIcon")
        case .stopped:
            Image("MenuBarIcon")
                .opacity(0.5)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
        }
    }
}
