import Foundation
import LinkoKit

/// The published state of the quick-add-rule window: a capture in flight, a
/// successfully captured page, or manual-input mode with optional guidance.
/// Owned by `AppState` (`quickAddCapture`) and rendered by `QuickAddRuleView`.
enum QuickAddCaptureState: Equatable {
    /// A page read is in flight; the window shows progress.
    case capturing
    /// The source browser's frontmost page URL was read successfully. The URL
    /// lives only in memory for the upcoming rule form — it is never logged
    /// (see the privacy contract on `BrowserPageReadError`).
    case captured(urlString: String)
    /// Automatic capture is unavailable; the user types the target instead.
    /// `guidance` explains why (`nil` when the window opens with no capture
    /// attempt behind it).
    case manual(QuickAddCapture.Guidance?)
}

/// Pure decision logic behind「为当前网页添加规则」: which application the
/// capture should read from, how a `BrowserPageReadError` maps onto a
/// user-facing failure category, and what guidance each category earns.
/// Deliberately AppKit-free so it stays unit-testable; `AppState` feeds it
/// value snapshots taken from NSWorkspace/CGWindowList.
enum QuickAddCapture {

    // MARK: - Reader timeouts

    /// Normal read budget: keeps the quick-add window responsive when the
    /// Automation permission is already settled.
    static let normalReadTimeout: TimeInterval = 1.0
    /// First-consent read budget: a pending Automation TCC prompt blocks
    /// osascript until the user answers it, so the dialog's on-screen time
    /// must not be billed against the normal budget.
    static let consentReadTimeout: TimeInterval = 30.0

    // MARK: - Source resolution

    /// Value snapshot of a candidate source application.
    struct SourceApp: Equatable, Sendable {
        let bundleID: String?
        let name: String?
    }

    /// Picks the app whose page the capture should read: the frontmost
    /// application, unless that is Linko itself (the user clicked our menu
    /// panel while one of our windows was key), in which case the owner of
    /// the frontmost normal-level window belonging to another app — i.e. the
    /// app the user was actually looking at. `nil` when no candidate exists.
    static func resolveSource(
        frontmost: SourceApp?,
        ownBundleID: String?,
        windowOwnersFrontToBack: [SourceApp]
    ) -> SourceApp? {
        if let frontmost, frontmost.bundleID != ownBundleID {
            return frontmost
        }
        return windowOwnersFrontToBack.first { $0.bundleID != ownBundleID }
    }

    // MARK: - Failure classification

    /// User-facing capture failure categories; each maps to one guidance.
    enum Failure: Equatable {
        /// No candidate application to read from at all.
        case noSourceApp
        /// The source app is not a browser the reader can script.
        case unsupportedApp(name: String?)
        /// Automation (TCC) permission for the browser is denied.
        case permissionDenied(browserName: String)
        /// The browser has no window to read from.
        case noWindow(browserName: String)
        /// The frontmost tab has no readable URL (e.g. a brand-new empty tab).
        case emptyOutput(browserName: String)
        /// The read timed out (or another read was still in flight).
        case timedOut(browserName: String)
        /// osascript failed in a way matching no more specific category.
        case scriptFailed(browserName: String)

        /// Maps a reader error onto its category. `appName` (the source
        /// app's display name) only backs `unsupportedBrowser`, whose error
        /// carries a bundle id rather than a friendly name.
        init(_ error: BrowserPageReadError, appName: String?) {
            switch error {
            case .unsupportedBrowser(let bundleID):
                self = .unsupportedApp(name: appName ?? bundleID)
            case .noWindow(let browserName):
                self = .noWindow(browserName: browserName)
            case .emptyOutput(let browserName):
                self = .emptyOutput(browserName: browserName)
            case .permissionDenied(let browserName):
                self = .permissionDenied(browserName: browserName)
            case .timedOut(let browserName):
                self = .timedOut(browserName: browserName)
            case .scriptFailed(let browserName):
                self = .scriptFailed(browserName: browserName)
            }
        }
    }

    // MARK: - Guidance

    /// What the quick-add window tells the user when a capture fails: a
    /// Chinese explanation plus, for a TCC denial, a shortcut into the
    /// Automation pane of System Settings.
    struct Guidance: Equatable, Sendable {
        let message: String
        /// `true` only for a permission denial — the one failure the user
        /// fixes in 系统设置 › 隐私与安全性 › 自动化.
        let offersAutomationSettings: Bool
    }

    /// The guidance a failure category earns. Every message ends in the
    /// manual fallback so the user always has a way forward.
    static func guidance(for failure: Failure) -> Guidance {
        switch failure {
        case .noSourceApp:
            return Guidance(
                message: "未能确定要读取的前台应用，请在下方手动输入网址或域名。",
                offersAutomationSettings: false
            )
        case .unsupportedApp(let name):
            let subject = name.map { "「\($0)」" } ?? "当前前台应用"
            return Guidance(
                message: "\(subject)不是受支持的浏览器（支持 Safari、Chrome、Edge、Arc、Brave），请在下方手动输入网址或域名。",
                offersAutomationSettings: false
            )
        case .permissionDenied(let browserName):
            return Guidance(
                message: "Linko 未获得控制 \(browserName) 的自动化权限，无法读取当前页面。请在系统设置中允许后重试，或在下方手动输入网址或域名。",
                offersAutomationSettings: true
            )
        case .noWindow(let browserName):
            return Guidance(
                message: "\(browserName) 当前没有打开的窗口，请在下方手动输入网址或域名。",
                offersAutomationSettings: false
            )
        case .emptyOutput(let browserName):
            return Guidance(
                message: "未能从 \(browserName) 的当前标签页读到网址（可能是空标签页），请在下方手动输入网址或域名。",
                offersAutomationSettings: false
            )
        case .timedOut(let browserName):
            return Guidance(
                message: "读取 \(browserName) 当前页面超时，请在下方手动输入网址或域名。",
                offersAutomationSettings: false
            )
        case .scriptFailed(let browserName):
            return Guidance(
                message: "读取 \(browserName) 当前页面失败，请在下方手动输入网址或域名。",
                offersAutomationSettings: false
            )
        }
    }
}
