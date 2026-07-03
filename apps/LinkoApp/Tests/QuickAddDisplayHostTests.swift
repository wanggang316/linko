import LinkoKit
import XCTest

/// Unit tests for `QuickAddRuleView.displayHost(from:)` — the captured-host
/// header derives from the same `DomainCandidateParser` as the form's
/// candidates, so the two surfaces can never disagree about a capture's host.
@MainActor
final class QuickAddDisplayHostTests: XCTestCase {

    func testDomainCaptureShowsTheFullHostname() {
        XCTAssertEqual(
            QuickAddRuleView.displayHost(from: "https://www.example.com/page?q=1"),
            "www.example.com"
        )
    }

    func testHostIsNormalizedLikeTheFormValues() {
        // Lowercased, FQDN trailing dot stripped, IDN labels punycode-encoded
        // — the exact spelling the form offers and saves.
        XCTAssertEqual(
            QuickAddRuleView.displayHost(from: "HTTPS://WWW.Example.COM./page"),
            "www.example.com"
        )
        XCTAssertEqual(
            QuickAddRuleView.displayHost(from: "https://bücher.example/"),
            "xn--bcher-kva.example"
        )
    }

    func testIPCaptureShowsTheCIDRLiteral() {
        XCTAssertEqual(
            QuickAddRuleView.displayHost(from: "http://192.168.1.1:8080/admin"),
            "192.168.1.1/32"
        )
        XCTAssertEqual(
            QuickAddRuleView.displayHost(from: "http://[::1]:8080/"),
            "::1/128"
        )
    }

    func testUnsupportedSchemeFallsBackToTheRawString() {
        // `URL(string:)` used to read "settings" out of this while the form
        // right below reported it could extract nothing; the header now
        // degrades exactly like the form does.
        XCTAssertEqual(
            QuickAddRuleView.displayHost(from: "chrome://settings/"),
            "chrome://settings/"
        )
    }

    func testAdversarialAuthorityAgreesWithTheFormCandidates() {
        // WHATWG URL parsing treats the backslash like a slash, so a browser
        // navigates to evil.com — while `URL(string:)?.host` reads good.com.
        // The header must show the host the form (and the browser) derive.
        let input = #"http://evil.com\@good.com/"#
        let displayed = QuickAddRuleView.displayHost(from: input)
        XCTAssertEqual(displayed, "evil.com")

        let form = QuickAddFormModel(capturedInput: input, defaultTarget: "proxy")
        XCTAssertTrue(
            form.candidates.contains { $0.value == displayed },
            "the header host must appear among the form's candidates"
        )
    }
}
