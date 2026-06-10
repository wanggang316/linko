import Combine
import Foundation
import Sparkle

/// Thin, observable wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// The standard controller owns the full update machinery — the `SPUUpdater`,
/// a standard user-driver (its own UI for "update available" / "downloading" /
/// "ready to install" sheets), and the wiring between them. We start it
/// immediately (`startingUpdater: true`) so Sparkle performs its scheduled
/// background checks per `SUFeedURL` / `SUScheduledCheckInterval` in Info.plist.
///
/// Runtime requires a real signed release + a hosted `appcast.xml` (see
/// docs/RELEASE.md). With the placeholder `SUFeedURL`, a manual check simply
/// reports "no update available" / a network error — compile and wiring are
/// fully exercised regardless.
///
/// MainActor-bound because every method ultimately drives AppKit UI through
/// Sparkle's user driver. App-target only — LinkoKit never links Sparkle.
@MainActor
final class UpdaterController: ObservableObject {
    /// Shared instance so both the menu bar footer and the Settings scene drive
    /// the same updater (Sparkle expects a single `SPUUpdater` per app).
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so SwiftUI can disable the
    /// "检查更新…" control while a check is already in flight.
    @Published private(set) var canCheckForUpdates = false

    /// Whether Sparkle automatically checks for updates on its schedule. Bound
    /// to a Settings toggle; writes flow straight through to the updater (which
    /// persists the choice in `UserDefaults` under Sparkle's own keys).
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    private var cancellable: AnyCancellable?

    private init() {
        // `startingUpdater: true` boots the updater on init; passing no delegates
        // keeps the standard (Sparkle-provided) UI and behavior.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        cancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }

    /// User-initiated update check. Shows Sparkle's standard progress/result UI.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
