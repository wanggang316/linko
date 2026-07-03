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

    func testNonCanonicalIPv4OctetsFailClosed() {
        // WHATWG/inet_aton parse leading-zero octets as octal; interpreting
        // them decimally would derive a rule for an address the browser
        // never connects to, so non-canonical spellings fail.
        XCTAssertNotNil(failure("010.8.8.8"))
        XCTAssertNotNil(failure("http://010.8.8.8/"))
        XCTAssertNotNil(failure("1.2.3.04"))
        XCTAssertNotNil(failure("1.2.3.004"))
        // The same canon applies to the IPv4 tail embedded in IPv6, which
        // would otherwise emit an ip_cidr sing-box cannot parse.
        XCTAssertNotNil(failure("::ffff:01.2.3.4"))
        XCTAssertNotNil(failure("[::ffff:01.2.3.4]:443"))

        // Canonical spellings keep parsing, including plain zeros.
        XCTAssertEqual(ipCandidate("0.0.0.0"), DomainCandidate(kind: .ipCIDR, value: "0.0.0.0/32"))
        XCTAssertEqual(
            ipCandidate("255.255.255.255"),
            DomainCandidate(kind: .ipCIDR, value: "255.255.255.255/32")
        )
        XCTAssertEqual(
            ipCandidate("::ffff:1.2.3.4"),
            DomainCandidate(kind: .ipCIDR, value: "::ffff:1.2.3.4/128")
        )
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
        XCTAssertEqual(domainCandidates("my-site.example.com")[1].value, "my-site.example.com")
        XCTAssertEqual(domainCandidates("123movies.com"), [
            DomainCandidate(kind: .suffix, value: "123movies.com"),
            DomainCandidate(kind: .keyword, value: "123movies"),
        ])
        XCTAssertEqual(domainCandidates("foo_bar.example.com")[1].value, "foo_bar.example.com")
    }

    func testOversizedHostsFailClosed() {
        // RFC 1035 limits, checked on the ASCII form: a host over 253 bytes
        // or any label over 63 bytes fails instead of splitting normally —
        // no resolver could match such a rule.
        let label61 = String(repeating: "a", count: 61)
        let overlongHost = ([label61, label61, label61, label61] + ["example", "com"])
            .joined(separator: ".")
        XCTAssertGreaterThan(overlongHost.count, 253)
        XCTAssertNotNil(failure("https://\(overlongHost)/"))
        XCTAssertNotNil(failure(overlongHost))

        let label64 = String(repeating: "a", count: 64)
        XCTAssertNotNil(failure("\(label64).example.com"))

        // Both limits are inclusive: a 63-byte label and a 253-byte host
        // still parse.
        let label63 = String(repeating: "a", count: 63)
        XCTAssertEqual(
            domainCandidates("\(label63).example.com")[1].value,
            "\(label63).example.com"
        )
        let host253 = [label63, label63, label63, String(repeating: "a", count: 57), "com"]
            .joined(separator: ".")
        XCTAssertEqual(host253.count, 253)
        XCTAssertEqual(domainCandidates(host253)[1].value, host253)

        // The limit applies to the punycode (wire) form: 60 raw characters
        // sit under 63, but their ACE encoding ("xn--" + 62 digits) does not.
        let wideLabel = String(repeating: "例", count: 60)
        XCTAssertNotNil(failure("\(wideLabel).example.com"))
    }

    func testOverlongUnicodeHostFailsFastBeforePunycodeEncoding() {
        // The scalar-count pre-check must reject oversized Unicode input
        // before the punycode encoder runs: the wire form is never shorter
        // than the scalar count, so 254+ scalars can never satisfy the
        // 253-byte limit. The bulk case pins the fast path — 20k *distinct*
        // scalars in one label would burn seconds inside the encoder if the
        // length check still ran after encoding.
        let minimalBreach = String(repeating: "例", count: 254)
        XCTAssertNotNil(failure(minimalBreach))
        XCTAssertNotNil(failure("https://\(minimalBreach)/"))

        var bulkLabel = ""
        bulkLabel.unicodeScalars.append(
            contentsOf: (0..<20_000).compactMap { Unicode.Scalar(0x4E00 + $0) }
        )
        XCTAssertNotNil(failure(bulkLabel))
        XCTAssertNotNil(failure("https://\(bulkLabel).example.com/"))
    }

    func testDecomposedUnicodeHostConvergesWithPrecomposedForm() {
        // NFC normalization: "café" typed as NFD ("cafe" + COMBINING ACUTE)
        // must produce the same ACE candidates as the precomposed spelling.
        let precomposed = "caf\u{00E9}.com"
        let decomposed = "cafe\u{0301}.com"
        XCTAssertEqual(parser.parse(decomposed), parser.parse(precomposed))
        XCTAssertEqual(domainCandidates(decomposed), [
            DomainCandidate(kind: .suffix, value: "xn--caf-dma.com"),
        ])
        XCTAssertEqual(
            parser.parse("https://www.\(decomposed)/path"),
            parser.parse("https://www.\(precomposed)/path")
        )
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

    func testBackslashTerminatesAuthorityLikeWHATWG() {
        // WHATWG URL parsing treats `\` like `/` in http(s) URLs: the host
        // here is evil.com. Cutting the authority only at `/` would strip
        // "evil.com\" as userinfo and derive good.com — a rule for a site
        // the browser never visited.
        XCTAssertEqual(domainCandidates("http://evil.com\\@good.com/")[0].value, "evil.com")
        XCTAssertEqual(
            parser.parse("http://example.com\\some\\path"),
            parser.parse("http://example.com/some/path")
        )
    }

    // MARK: - Error payload discipline

    func testFailurePayloadsNeverCarryURLDerivedData() {
        // Error associated values carry only static categories — never the
        // authority, host, port or any other fragment of the input — so an
        // error can reach a log line without leaking where the user browsed.
        let secret = "secret-host"
        let failingInputs = [
            "user:pass@\(secret).example.com",  // userinfo without a scheme
            "http://[\(secret)::1/path",        // unbalanced IPv6 brackets
            "http://[::1]\(secret)",            // invalid text after brackets
            "\(secret).example.com:port",       // non-numeric port
            "\(secret)!.example.com",           // disallowed host character
            "\(secret)..example.com",           // empty label
            "\(secret)::\(secret)::1",          // invalid IPv6 literal
            "\(String(repeating: "a", count: 64)).\(secret).example.com", // oversized label
        ]
        for input in failingInputs {
            guard case .failure(let error) = parser.parse(input) else {
                XCTFail("expected failure for \(input)")
                continue
            }
            let description = String(describing: error)
            XCTAssertFalse(description.contains(secret), "\(input) leaked into: \(description)")
        }
    }
}
