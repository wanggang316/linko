import XCTest
@testable import LinkoKit

/// Grammar tests for the `linko://` URL scheme parser — the shared vocabulary
/// the in-app handler and the `scripts/linko` CLI both speak.
final class LinkoURLSchemeTests: XCTestCase {
    private func parse(_ string: String) -> LinkoCommand? {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return nil
        }
        return LinkoURLScheme.command(from: url)
    }

    func testProxyOnOffToggle() {
        XCTAssertEqual(parse("linko://on"), .enableProxy)
        XCTAssertEqual(parse("linko://enable"), .enableProxy)
        XCTAssertEqual(parse("linko://off"), .disableProxy)
        XCTAssertEqual(parse("linko://disable"), .disableProxy)
        XCTAssertEqual(parse("linko://toggle"), .toggleProxy)
    }

    func testCaseInsensitiveSchemeAndAction() {
        XCTAssertEqual(parse("LINKO://TOGGLE"), .toggleProxy)
        XCTAssertEqual(parse("Linko://On"), .enableProxy)
    }

    func testLeadingSlashFormAlsoWorks() {
        XCTAssertEqual(parse("linko:///toggle"), .toggleProxy)
    }

    func testMode() {
        XCTAssertEqual(parse("linko://mode?value=tun"), .setMode(.tun))
        XCTAssertEqual(parse("linko://mode?value=system"), .setMode(.systemProxy))
        XCTAssertEqual(parse("linko://mode?value=system-proxy"), .setMode(.systemProxy))
        XCTAssertNil(parse("linko://mode?value=bogus"))
        XCTAssertNil(parse("linko://mode"))
    }

    func testSelectNode() {
        XCTAssertEqual(parse("linko://select?node=US%201"), .selectNode(name: "US 1"))
        XCTAssertEqual(parse("linko://select?node=%E9%A6%99%E6%B8%AF"), .selectNode(name: "香港"))
        XCTAssertNil(parse("linko://select"))
        XCTAssertNil(parse("linko://select?node="))
    }

    func testSwitchProfile() {
        XCTAssertEqual(parse("linko://profile?name=Work"), .switchProfile(name: "Work"))
        XCTAssertNil(parse("linko://profile?name=%20%20"))
    }

    func testInstallConfig() {
        XCTAssertEqual(
            parse("linko://install-config?url=https%3A%2F%2Fexample.com%2Fsub&name=My%20Sub"),
            .installConfig(url: URL(string: "https://example.com/sub")!, name: "My Sub")
        )
        // name is optional.
        XCTAssertEqual(
            parse("linko://install-config?url=http%3A%2F%2Fa.test%2Fc"),
            .installConfig(url: URL(string: "http://a.test/c")!, name: nil)
        )
    }

    func testInstallConfigRejectsNonHTTPURL() {
        // A file:// or data: URL must not be importable through the scheme.
        XCTAssertNil(parse("linko://install-config?url=file%3A%2F%2F%2Fetc%2Fpasswd"))
        XCTAssertNil(parse("linko://install-config?url=javascript%3Aalert(1)"))
        XCTAssertNil(parse("linko://install-config"))
    }

    func testTestDelays() {
        XCTAssertEqual(parse("linko://test"), .testDelays)
    }

    func testUnknownActionsAndForeignSchemes() {
        XCTAssertNil(parse("linko://wat"))
        XCTAssertNil(parse("https://on"))
        XCTAssertNil(parse("surge://toggle"))
    }

    func testConfirmationRequiredOnlyForInstall() {
        XCTAssertTrue(LinkoCommand.installConfig(url: URL(string: "https://a.test")!, name: nil).requiresConfirmation)
        XCTAssertFalse(LinkoCommand.toggleProxy.requiresConfirmation)
        XCTAssertFalse(LinkoCommand.disableProxy.requiresConfirmation)
        XCTAssertFalse(LinkoCommand.setMode(.tun).requiresConfirmation)
    }
}
