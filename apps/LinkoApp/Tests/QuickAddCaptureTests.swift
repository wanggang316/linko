import LinkoKit
import XCTest

/// Unit tests for `QuickAddCapture` — the pure decision logic behind
/// 为当前网页添加规则: source-app resolution (VAL-CAPTURE-021), reader-error
/// classification, and the failure → guidance mapping (VAL-CAPTURE-005/006).
final class QuickAddCaptureTests: XCTestCase {

    private let linkoBundleID = "com.gumpw.linko"

    private func app(_ bundleID: String?, name: String? = nil) -> QuickAddCapture.SourceApp {
        QuickAddCapture.SourceApp(bundleID: bundleID, name: name)
    }

    // MARK: - Source resolution

    func testFrontmostNonLinkoAppIsTheSource() {
        let safari = app("com.apple.Safari", name: "Safari")

        let resolved = QuickAddCapture.resolveSource(
            frontmost: safari,
            ownBundleID: linkoBundleID,
            windowOwnersFrontToBack: [app("com.google.Chrome", name: "Google Chrome")]
        )

        XCTAssertEqual(resolved, safari)
    }

    func testFrontmostLinkoFallsBackToFrontmostOtherWindowOwner() {
        // Linko is frontmost (e.g. the dashboard window is key); the source
        // must be the next app in window z-order, skipping Linko's own
        // windows (VAL-CAPTURE-021).
        let resolved = QuickAddCapture.resolveSource(
            frontmost: app(linkoBundleID, name: "Linko"),
            ownBundleID: linkoBundleID,
            windowOwnersFrontToBack: [
                app(linkoBundleID, name: "Linko"),
                app("com.apple.Safari", name: "Safari"),
                app("com.google.Chrome", name: "Google Chrome"),
            ]
        )

        XCTAssertEqual(resolved, app("com.apple.Safari", name: "Safari"))
    }

    func testNoCandidateResolvesToNil() {
        XCTAssertNil(QuickAddCapture.resolveSource(
            frontmost: nil,
            ownBundleID: linkoBundleID,
            windowOwnersFrontToBack: []
        ))
        // Only Linko itself on screen: still no source.
        XCTAssertNil(QuickAddCapture.resolveSource(
            frontmost: app(linkoBundleID),
            ownBundleID: linkoBundleID,
            windowOwnersFrontToBack: [app(linkoBundleID)]
        ))
    }

    func testFrontmostAppWithoutBundleIDStillCounts() {
        // A bundle-id-less process can never be Linko itself, so it remains
        // a legitimate (unsupported) source rather than being skipped.
        let anonymous = app(nil, name: "SomeTool")

        let resolved = QuickAddCapture.resolveSource(
            frontmost: anonymous,
            ownBundleID: linkoBundleID,
            windowOwnersFrontToBack: []
        )

        XCTAssertEqual(resolved, anonymous)
    }

    // MARK: - Failure classification

    func testReaderErrorsMapToMatchingFailureCategories() {
        let cases: [(BrowserPageReadError, QuickAddCapture.Failure)] = [
            (.noWindow(browserName: "Safari"), .noWindow(browserName: "Safari")),
            (.emptyOutput(browserName: "Safari"), .emptyOutput(browserName: "Safari")),
            (.permissionDenied(browserName: "Safari"), .permissionDenied(browserName: "Safari")),
            (.timedOut(browserName: "Safari"), .timedOut(browserName: "Safari")),
            (.scriptFailed(browserName: "Safari"), .scriptFailed(browserName: "Safari")),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(QuickAddCapture.Failure(error, appName: nil), expected)
        }
    }

    func testUnsupportedBrowserErrorPrefersTheAppDisplayName() {
        XCTAssertEqual(
            QuickAddCapture.Failure(.unsupportedBrowser(bundleID: "com.apple.finder"), appName: "Finder"),
            .unsupportedApp(name: "Finder")
        )
        // Without a display name the bundle id is better than nothing.
        XCTAssertEqual(
            QuickAddCapture.Failure(.unsupportedBrowser(bundleID: "com.apple.finder"), appName: nil),
            .unsupportedApp(name: "com.apple.finder")
        )
    }

    // MARK: - Guidance

    private var allFailures: [QuickAddCapture.Failure] {
        [
            .noSourceApp,
            .unsupportedApp(name: "Finder"),
            .unsupportedApp(name: nil),
            .permissionDenied(browserName: "Safari"),
            .noWindow(browserName: "Safari"),
            .emptyOutput(browserName: "Safari"),
            .timedOut(browserName: "Safari"),
            .scriptFailed(browserName: "Safari"),
        ]
    }

    func testOnlyPermissionDenialOffersTheAutomationSettingsShortcut() {
        // VAL-CAPTURE-005: a denial gets the System Settings pointer; every
        // other failure degrades to plain manual input.
        for failure in allFailures {
            let guidance = QuickAddCapture.guidance(for: failure)
            XCTAssertEqual(
                guidance.offersAutomationSettings,
                failure == .permissionDenied(browserName: "Safari"),
                "unexpected settings shortcut for \(failure)"
            )
        }
    }

    func testEveryGuidancePointsToManualInput() {
        for failure in allFailures {
            XCTAssertTrue(
                QuickAddCapture.guidance(for: failure).message.contains("手动输入"),
                "guidance for \(failure) lacks the manual fallback"
            )
        }
    }

    func testGuidanceNamesTheAppItTalksAbout() {
        XCTAssertTrue(QuickAddCapture.guidance(
            for: .permissionDenied(browserName: "Safari")).message.contains("Safari"))
        XCTAssertTrue(QuickAddCapture.guidance(
            for: .noWindow(browserName: "Arc")).message.contains("Arc"))
        XCTAssertTrue(QuickAddCapture.guidance(
            for: .unsupportedApp(name: "Finder")).message.contains("「Finder」"))
    }
}
