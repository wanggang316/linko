import XCTest
@testable import LinkoKit

final class DomainCandidatesTests: XCTestCase {
    private let parser = DomainCandidateParser()

    // MARK: - Helpers

    /// Unwraps a `.domain` outcome (running the shape invariants) or fails.
    private func domainCandidates(
        _ input: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [DomainCandidate] {
        switch parser.parse(input) {
        case .success(.domain(let candidates)):
            assertShape(.domain(candidates), input: input, file: file, line: line)
            return candidates
        case .success(.ip(let candidate)):
            XCTFail("expected domain candidates for \(input), got IP \(candidate.value)", file: file, line: line)
            return []
        case .failure(let error):
            XCTFail("expected domain candidates for \(input), got \(error)", file: file, line: line)
            return []
        }
    }

    /// Unwraps an `.ip` outcome (running the shape invariants) or fails.
    private func ipCandidate(
        _ input: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> DomainCandidate? {
        switch parser.parse(input) {
        case .success(.ip(let candidate)):
            assertShape(.ip(candidate), input: input, file: file, line: line)
            return candidate
        case .success(.domain(let candidates)):
            XCTFail("expected an IP candidate for \(input), got \(candidates.map(\.value))", file: file, line: line)
            return nil
        case .failure(let error):
            XCTFail("expected an IP candidate for \(input), got \(error)", file: file, line: line)
            return nil
        }
    }

    /// Unwraps a failure or fails the test on success.
    private func failure(
        _ input: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> DomainCandidateError? {
        switch parser.parse(input) {
        case .success(let outcome):
            XCTFail("expected failure for \(input), got \(outcome.candidates.map(\.value))", file: file, line: line)
            return nil
        case .failure(let error):
            return error
        }
    }

    /// VAL-DOMAIN-011/012: shape invariants every successful outcome must hold.
    private func assertShape(
        _ outcome: DomainCandidateOutcome,
        input: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let candidates = outcome.candidates
        XCTAssertFalse(candidates.isEmpty, "success must never be empty (\(input))", file: file, line: line)
        XCTAssertEqual(outcome.defaultCandidate, candidates[0], "default is the first candidate (\(input))", file: file, line: line)
        XCTAssertEqual(Set(candidates.map(\.kind)).count, candidates.count, "at most one candidate per kind (\(input))", file: file, line: line)
        XCTAssertEqual(Set(candidates).count, candidates.count, "no duplicate candidates (\(input))", file: file, line: line)

        for candidate in candidates {
            let value = candidate.value
            XCTAssertFalse(value.isEmpty, "empty value (\(input))", file: file, line: line)
            XCTAssertEqual(value, value.trimmingCharacters(in: .whitespacesAndNewlines), "whitespace in \(value) (\(input))", file: file, line: line)
            XCTAssertEqual(value, value.lowercased(), "uppercase in \(value) (\(input))", file: file, line: line)
            XCTAssertFalse(value.contains("://"), "scheme in \(value) (\(input))", file: file, line: line)
            XCTAssertFalse(value.contains(","), "comma in \(value) (\(input))", file: file, line: line)
            XCTAssertFalse(value.contains(" "), "space in \(value) (\(input))", file: file, line: line)

            switch candidate.kind {
            case .suffix, .host, .keyword:
                XCTAssertFalse(value.hasPrefix("."), "leading dot in \(value) (\(input))", file: file, line: line)
                XCTAssertFalse(value.hasSuffix("."), "trailing dot in \(value) (\(input))", file: file, line: line)
                XCTAssertFalse(value.contains("/"), "slash in \(value) (\(input))", file: file, line: line)
                XCTAssertFalse(value.contains(":"), "port or colon in \(value) (\(input))", file: file, line: line)
                XCTAssertFalse(value.contains("@"), "credentials in \(value) (\(input))", file: file, line: line)
                if candidate.kind == .keyword {
                    XCTAssertFalse(value.contains("."), "dot in keyword \(value) (\(input))", file: file, line: line)
                }
            case .ipCIDR:
                let parts = value.split(separator: "/")
                XCTAssertEqual(parts.count, 2, "malformed CIDR \(value) (\(input))", file: file, line: line)
                XCTAssertTrue(parts.last == "32" || parts.last == "128", "bad prefix length in \(value) (\(input))", file: file, line: line)
                if parts.last == "32" {
                    XCTAssertEqual(parts.first?.split(separator: ".").count, 4, "bad IPv4 in \(value) (\(input))", file: file, line: line)
                } else {
                    XCTAssertTrue(parts.first?.contains(":") == true, "bad IPv6 in \(value) (\(input))", file: file, line: line)
                }
                XCTAssertFalse(value.contains("["), "brackets in \(value) (\(input))", file: file, line: line)
                XCTAssertFalse(value.contains("]"), "brackets in \(value) (\(input))", file: file, line: line)
            }
        }
    }

    // MARK: - VAL-DOMAIN-001

    func testFullURLYieldsSuffixHostAndKeyword() {
        XCTAssertEqual(domainCandidates("https://www.google.com/search?q=x"), [
            DomainCandidate(kind: .suffix, value: "google.com"),
            DomainCandidate(kind: .host, value: "www.google.com"),
            DomainCandidate(kind: .keyword, value: "google"),
        ])
    }

    func testCandidatesDependOnlyOnHost() {
        let base = parser.parse("https://www.google.com/search?q=x")
        for variant in [
            "http://www.google.com/search?q=x",
            "https://www.google.com/other/path#fragment",
            "https://www.google.com",
            "www.google.com",
            "www.google.com/search?q=x",
        ] {
            XCTAssertEqual(parser.parse(variant), base, "candidates for \(variant) must only depend on the host")
        }
    }

    // MARK: - VAL-DOMAIN-002

    func testRegistrableHostYieldsSuffixAndKeywordOnly() {
        XCTAssertEqual(domainCandidates("https://example.com/"), [
            DomainCandidate(kind: .suffix, value: "example.com"),
            DomainCandidate(kind: .keyword, value: "example"),
        ])
    }

    // MARK: - VAL-DOMAIN-003

    func testSecondLevelTLDTableSplitsRegistrableDomain() {
        XCTAssertEqual(domainCandidates("https://bbc.co.uk/")[0], DomainCandidate(kind: .suffix, value: "bbc.co.uk"))
        XCTAssertEqual(domainCandidates("https://news.example.com.cn/")[0].value, "example.com.cn")
        XCTAssertEqual(domainCandidates("https://a.b.c.d.example.co.jp/"), [
            DomainCandidate(kind: .suffix, value: "example.co.jp"),
            DomainCandidate(kind: .host, value: "a.b.c.d.example.co.jp"),
            DomainCandidate(kind: .keyword, value: "example"),
        ])
        // gov.cn is in the table, so www.gov.cn is itself the registrable
        // domain; "www" is too short to keyword.
        XCTAssertEqual(domainCandidates("https://www.gov.cn/"), [
            DomainCandidate(kind: .suffix, value: "www.gov.cn"),
        ])
    }

    // MARK: - VAL-DOMAIN-004

    func testRequiredTableEntriesAndFallbackToLastTwoLabels() {
        for suffix in ["com.cn", "co.uk", "co.jp", "com.hk", "com.tw", "com.au"] {
            XCTAssertEqual(
                domainCandidates("https://a.example.\(suffix)/")[0],
                DomainCandidate(kind: .suffix, value: "example.\(suffix)"),
                "registrable domain under \(suffix)"
            )
        }
        // A multi-label suffix not in the table falls back to the last two labels.
        XCTAssertEqual(domainCandidates("https://user.github.io/")[0].value, "github.io")
    }

    // MARK: - VAL-DOMAIN-005

    func testHostNormalizationStripsCredentialsPortCaseAndTrailingDot() {
        XCTAssertEqual(domainCandidates("HTTPS://user:pass@WWW.Example.COM.:8443/"), [
            DomainCandidate(kind: .suffix, value: "example.com"),
            DomainCandidate(kind: .host, value: "www.example.com"),
            DomainCandidate(kind: .keyword, value: "example"),
        ])
    }

    // MARK: - VAL-DOMAIN-006

    func testIDNInputsProducePunycodeCandidates() {
        XCTAssertEqual(domainCandidates("https://例子.中国/"), [
            DomainCandidate(kind: .suffix, value: "xn--fsqu00a.xn--fiqs8s"),
        ])
        // Unicode and already-encoded inputs converge on identical results.
        XCTAssertEqual(parser.parse("https://例子.中国/"), parser.parse("https://xn--fsqu00a.xn--fiqs8s/"))
        XCTAssertEqual(domainCandidates("https://www.例子.中国/"), [
            DomainCandidate(kind: .suffix, value: "xn--fsqu00a.xn--fiqs8s"),
            DomainCandidate(kind: .host, value: "www.xn--fsqu00a.xn--fiqs8s"),
        ])
    }

    // MARK: - VAL-DOMAIN-007

    func testIPInputsYieldSingleCIDRCandidate() {
        XCTAssertEqual(ipCandidate("http://1.2.3.4:8080/"), DomainCandidate(kind: .ipCIDR, value: "1.2.3.4/32"))
        XCTAssertEqual(ipCandidate("1.2.3.4:8080"), DomainCandidate(kind: .ipCIDR, value: "1.2.3.4/32"))
        XCTAssertEqual(ipCandidate("1.2.3.4"), DomainCandidate(kind: .ipCIDR, value: "1.2.3.4/32"))
        XCTAssertEqual(ipCandidate("[2001:db8::1]:8080"), DomainCandidate(kind: .ipCIDR, value: "2001:db8::1/128"))
        XCTAssertEqual(ipCandidate("2001:db8::1"), DomainCandidate(kind: .ipCIDR, value: "2001:db8::1/128"))
        XCTAssertEqual(ipCandidate("https://[2001:db8::1]:8080/path"), DomainCandidate(kind: .ipCIDR, value: "2001:db8::1/128"))
    }

    // MARK: - VAL-DOMAIN-008

    func testSingleLabelHostsYieldExactDomainCandidate() {
        let cases: [(input: String, host: String)] = [
            ("localhost", "localhost"),
            ("router", "router"),
            ("nas:5000", "nas"),
            ("http://localhost:3000/admin", "localhost"),
        ]
        for (input, host) in cases {
            XCTAssertEqual(
                domainCandidates(input),
                [DomainCandidate(kind: .host, value: host)],
                "single-label host for \(input)"
            )
        }
    }

    // MARK: - VAL-DOMAIN-009

    func testUnsupportedSchemesAndMalformedInputsFail() {
        XCTAssertEqual(failure("file:///etc/hosts"), .unsupportedScheme("file"))
        XCTAssertEqual(failure("file://example.com/x"), .unsupportedScheme("file"))
        XCTAssertEqual(failure("chrome://settings"), .unsupportedScheme("chrome"))
        XCTAssertNotNil(failure("about:blank"))
        XCTAssertNotNil(failure("data:text/html,<h1>hi</h1>"))
        XCTAssertEqual(failure(""), .emptyInput)
        XCTAssertEqual(failure("   \n\t "), .emptyInput)
        XCTAssertNotNil(failure("not a url"))
        XCTAssertEqual(failure("http://"), .missingHost)
        XCTAssertEqual(failure("http://:8080"), .missingHost)
        XCTAssertNotNil(failure("a..example.com"))
    }

    // MARK: - VAL-DOMAIN-010

    func testUnusualButValidHostsParse() {
        // Longer than 253 characters still splits normally.
        let label = String(repeating: "a", count: 61)
        let host = ([label, label, label, label] + ["example", "com"]).joined(separator: ".")
        XCTAssertGreaterThan(host.count, 253)
        let long = domainCandidates("https://\(host)/")
        XCTAssertEqual(long[0].value, "example.com")
        XCTAssertEqual(long[1], DomainCandidate(kind: .host, value: host))

        XCTAssertEqual(domainCandidates("my-site.example.com")[1].value, "my-site.example.com")
        XCTAssertEqual(domainCandidates("123movies.com"), [
            DomainCandidate(kind: .suffix, value: "123movies.com"),
            DomainCandidate(kind: .keyword, value: "123movies"),
        ])
        XCTAssertEqual(domainCandidates("foo_bar.example.com")[1].value, "foo_bar.example.com")
    }

    // MARK: - VAL-DOMAIN-011

    func testShapeInvariantsAcrossInputs() {
        let inputs = [
            "https://www.google.com/search?q=x",
            "HTTPS://user:pass@WWW.Example.COM.:8443/",
            "https://例子.中国/",
            "https://xn--fsqu00a.xn--fiqs8s/",
            "bbc.co.uk",
            "news.example.com.cn",
            "user.github.io",
            "localhost",
            "nas:5000",
            "co.uk",
            "1.2.3.4",
            "1.2.3.4:8080",
            "[2001:db8::1]:8080",
            "2001:db8::1",
            "123movies.com",
            "foo_bar.example.com",
            "my-site.example.com",
            "1.2.3.4.example.com",
            "cdn.assets.stripe.com",
            "https://www.gov.cn/",
        ]
        for input in inputs {
            guard case .success(let outcome) = parser.parse(input) else {
                XCTFail("expected success for \(input)")
                continue
            }
            assertShape(outcome, input: input)
        }
    }

    // MARK: - VAL-DOMAIN-012

    func testKindSetIsClosedAndMapsOntoRuleTypes() {
        XCTAssertEqual(Set(DomainCandidate.Kind.allCases), [.suffix, .host, .keyword, .ipCIDR])
        XCTAssertEqual(DomainCandidate.Kind.suffix.ruleType, .domainSuffix)
        XCTAssertEqual(DomainCandidate.Kind.host.ruleType, .domain)
        XCTAssertEqual(DomainCandidate.Kind.keyword.ruleType, .domainKeyword)
        XCTAssertEqual(DomainCandidate.Kind.ipCIDR.ruleType, .ipCIDR)
        XCTAssertEqual(DomainCandidate(kind: .suffix, value: "example.com").ruleType.rawValue, "DOMAIN-SUFFIX")
    }

    func testDefaultCandidateIsExplicitAndOrderIsFixed() {
        guard case .success(let outcome) = parser.parse("https://www.google.com/") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(outcome.defaultCandidate, outcome.candidates[0])
        XCTAssertEqual(outcome.defaultCandidate.kind, .suffix)
        XCTAssertEqual(outcome.candidates.map(\.kind), [.suffix, .host, .keyword])
    }

    // MARK: - VAL-DOMAIN-013

    func testKeywordIsLeftmostRegistrableLabelWithSuppression() {
        XCTAssertTrue(domainCandidates("news.example.com.cn").contains(DomainCandidate(kind: .keyword, value: "example")))
        XCTAssertEqual(domainCandidates("cdn.assets.stripe.com"), [
            DomainCandidate(kind: .suffix, value: "stripe.com"),
            DomainCandidate(kind: .host, value: "cdn.assets.stripe.com"),
            DomainCandidate(kind: .keyword, value: "stripe"),
        ])
        // Exactly 4 characters is the shortest label that still keywords.
        XCTAssertTrue(domainCandidates("epic.com").contains(DomainCandidate(kind: .keyword, value: "epic")))
        // Registrable labels shorter than 4 characters produce no keyword.
        for input in ["t.co", "x.com", "qq.com", "bbc.co.uk"] {
            XCTAssertFalse(
                domainCandidates(input).contains { $0.kind == .keyword },
                "no keyword for \(input)"
            )
        }
        // Punycode labels produce no keyword.
        XCTAssertFalse(domainCandidates("https://例子.中国/").contains { $0.kind == .keyword })
    }

    // MARK: - VAL-DOMAIN-014

    func testHostEqualToTableSuffixFallsBackToExactDomain() {
        XCTAssertEqual(domainCandidates("https://co.uk/"), [DomainCandidate(kind: .host, value: "co.uk")])
        XCTAssertEqual(domainCandidates("gov.cn"), [DomainCandidate(kind: .host, value: "gov.cn")])
    }

    // MARK: - VAL-DOMAIN-015

    func testSchemelessInputsMatchTheirURLForms() {
        let pairs: [(schemeless: String, url: String)] = [
            ("example.com", "https://example.com/"),
            ("www.example.com/path", "https://www.example.com/path"),
            ("example.com:8443", "https://example.com:8443/"),
            ("example.com:8443/path", "https://example.com:8443/path"),
        ]
        for (schemeless, url) in pairs {
            XCTAssertEqual(parser.parse(schemeless), parser.parse(url), "schemeless \(schemeless) must match \(url)")
        }
    }

    func testSchemelessDiscriminationEdgeCases() {
        XCTAssertEqual(domainCandidates("nas:5000"), [DomainCandidate(kind: .host, value: "nas")])
        XCTAssertNotNil(failure("about:blank"))
        XCTAssertNotNil(failure("user:pass@example.com"))
        // Not all-numeric: a domain whose registrable domain is example.com.
        XCTAssertEqual(domainCandidates("1.2.3.4.example.com")[0].value, "example.com")
        // Dotted all-numeric input is IPv4 or nothing.
        XCTAssertNotNil(failure("256.1.1.1"))
        XCTAssertNotNil(failure("1.2.3.4.5"))
    }
}
