import LinkoKit
import XCTest

/// Unit tests for `QuickAddFormModel` — the pure state model behind the
/// quick-add rule form: prefill defaults (VAL-QUICKADD-001/012), the
/// candidate/type two-way pairing (VAL-QUICKADD-002/003/017/022), the
/// normalization pipeline (VAL-QUICKADD-009/016/020), validation
/// (VAL-QUICKADD-008), the restricted type range (VAL-QUICKADD-021), and the
/// idempotent commit (VAL-QUICKADD-011).
final class QuickAddFormModelTests: XCTestCase {

    private let proxy = "proxy"

    private func form(capturing input: String?) -> QuickAddFormModel {
        QuickAddFormModel(capturedInput: input, defaultTarget: proxy)
    }

    // MARK: - Prefill

    func testCapturedDomainURLPrefillsRegistrableSuffixAndProxyTarget() {
        // VAL-QUICKADD-001: capture → registrable-domain candidate selected,
        // type 域名后缀, target defaults to proxy (never reject).
        let model = form(capturing: "https://www.example.com/page?q=1")

        XCTAssertEqual(model.ruleType, .domainSuffix)
        XCTAssertEqual(model.value, "example.com")
        XCTAssertEqual(model.targetTag, proxy)
        XCTAssertEqual(model.scenario, .domain)
        XCTAssertNil(model.prefillProblem)
        XCTAssertNil(model.validationProblem)
        XCTAssertEqual(model.candidates, [
            DomainCandidate(kind: .suffix, value: "example.com"),
            DomainCandidate(kind: .host, value: "www.example.com"),
            DomainCandidate(kind: .keyword, value: "example"),
        ])
        XCTAssertEqual(model.selectedCandidate, model.candidates.first)
    }

    func testTypeRangeIsRestrictedToDomainKinds() {
        // VAL-QUICKADD-021: exactly the three domain matchers — no final,
        // logical, process, or other kinds from the full editor.
        let model = form(capturing: "https://www.example.com/")

        XCTAssertEqual(model.availableTypes, [.domainSuffix, .domain, .domainKeyword])
    }

    func testCapturedIPURLPrefillsIPCIDR() {
        // VAL-QUICKADD-012: an IP page prefills a single /32 IP-CIDR
        // candidate, and the type range collapses to IP-CIDR.
        let model = form(capturing: "http://192.168.1.1:8080/admin")

        XCTAssertEqual(model.scenario, .ip)
        XCTAssertEqual(model.ruleType, .ipCIDR)
        XCTAssertEqual(model.value, "192.168.1.1/32")
        XCTAssertEqual(model.candidates, [DomainCandidate(kind: .ipCIDR, value: "192.168.1.1/32")])
        XCTAssertEqual(model.availableTypes, [.ipCIDR])
        XCTAssertNil(model.validationProblem)
    }

    func testCapturedLocalhostPrefillsExactDomain() {
        // VAL-QUICKADD-012: a single-label host has no registrable domain and
        // presents as one exact DOMAIN candidate.
        let model = form(capturing: "http://localhost:3000/")

        XCTAssertEqual(model.ruleType, .domain)
        XCTAssertEqual(model.value, "localhost")
        XCTAssertEqual(model.candidates, [DomainCandidate(kind: .host, value: "localhost")])
    }

    func testUnparseableCaptureFallsBackToManualWithNote() {
        // VAL-QUICKADD-008: about:blank yields no candidates — manual mode
        // with an explanatory note, saving blocked until the user types.
        var model = form(capturing: "about:blank")

        XCTAssertNotNil(model.prefillProblem)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertEqual(model.value, "")
        XCTAssertEqual(model.ruleType, .domainSuffix)
        XCTAssertNotNil(model.validationProblem)
        XCTAssertNil(model.commitRule())
    }

    func testManualModeStartsEmptyWithoutNote() {
        let model = form(capturing: nil)

        XCTAssertNil(model.prefillProblem)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertEqual(model.value, "")
        XCTAssertEqual(model.ruleType, .domainSuffix)
        XCTAssertEqual(model.validationProblem, "请输入匹配值")
    }

    // MARK: - Candidate / type pairing

    func testSelectingCandidateUpdatesTypeAndValueAsAPair() {
        // VAL-QUICKADD-002/003/017: a candidate click moves both fields to
        // that candidate's kind and value.
        var model = form(capturing: "https://www.example.com/")

        model.selectCandidate(DomainCandidate(kind: .host, value: "www.example.com"))
        XCTAssertEqual(model.ruleType, .domain)
        XCTAssertEqual(model.value, "www.example.com")

        model.selectCandidate(DomainCandidate(kind: .keyword, value: "example"))
        XCTAssertEqual(model.ruleType, .domainKeyword)
        XCTAssertEqual(model.value, "example")

        model.selectCandidate(DomainCandidate(kind: .suffix, value: "example.com"))
        XCTAssertEqual(model.ruleType, .domainSuffix)
        XCTAssertEqual(model.value, "example.com")
    }

    func testSelectingTypeRederivesValueFromThatTypesCandidate() {
        // VAL-QUICKADD-002: switching the type directly re-derives the value
        // from the matching candidate, keeping type and value paired.
        var model = form(capturing: "https://www.example.com/")

        model.selectType(.domain)
        XCTAssertEqual(model.value, "www.example.com")
        XCTAssertEqual(model.selectedCandidate?.kind, .host)

        model.selectType(.domainKeyword)
        XCTAssertEqual(model.value, "example")

        model.selectType(.domainSuffix)
        XCTAssertEqual(model.value, "example.com")
    }

    func testSelectingTypeWithoutCandidateKeepsValueEditable() {
        // VAL-QUICKADD-022: a short registrable label ("ab") suppresses the
        // keyword candidate; switching to 域名关键词 keeps the current value
        // editable, and clearing it blocks saving.
        var model = form(capturing: "https://ab.cn/")
        XCTAssertEqual(model.candidates, [DomainCandidate(kind: .suffix, value: "ab.cn")])

        model.selectType(.domainKeyword)
        XCTAssertEqual(model.ruleType, .domainKeyword)
        XCTAssertEqual(model.value, "ab.cn")
        XCTAssertNil(model.selectedCandidate)
        XCTAssertNil(model.validationProblem)

        model.updateValue("")
        XCTAssertEqual(model.validationProblem, "请输入匹配值")
        XCTAssertNil(model.commitRule())
    }

    func testManualEditDeselectsCandidateUntilItMatchesAgain() {
        var model = form(capturing: "https://www.example.com/")

        model.updateValue("sub.example.com")
        XCTAssertNil(model.selectedCandidate)

        model.selectCandidate(DomainCandidate(kind: .suffix, value: "example.com"))
        XCTAssertEqual(model.selectedCandidate?.kind, .suffix)
    }

    func testIgnoresTypeAndCandidateOutsideTheAllowedRange() {
        var model = form(capturing: "https://www.example.com/")

        model.selectType(.final)
        XCTAssertEqual(model.ruleType, .domainSuffix)

        model.selectCandidate(DomainCandidate(kind: .ipCIDR, value: "10.0.0.1/32"))
        XCTAssertEqual(model.value, "example.com")
    }

    // MARK: - Normalization pipeline

    func testWholeURLPasteNormalizesToHostnameOnCommit() {
        // VAL-QUICKADD-009: a pasted URL reduces to its trimmed, lowercased
        // hostname; the saved rule keeps the chosen type.
        var model = form(capturing: nil)
        model.updateValue("  https://WWW.Example.COM/path?q=1  ")

        XCTAssertNil(model.validationProblem)
        let rule = model.commitRule()
        XCTAssertEqual(rule?.type, .domainSuffix)
        XCTAssertEqual(rule?.value, "www.example.com")
        XCTAssertEqual(rule?.target, proxy)
    }

    func testManualRewriteKeepsTheEditedHostVerbatim() {
        // VAL-QUICKADD-016: rewriting the suffix value to a deeper host must
        // save that host — never silently remap to the registrable domain.
        var model = form(capturing: "https://www.example.com/")
        model.updateValue("sub.example.com")

        let rule = model.commitRule()
        XCTAssertEqual(rule?.type, .domainSuffix)
        XCTAssertEqual(rule?.value, "sub.example.com")
    }

    func testManualIPInputFlipsToIPCIDRAndSavesCIDR() {
        // VAL-QUICKADD-012: a legal IP typed by hand flips the scenario and
        // saves as an IP-CIDR rule.
        var model = form(capturing: nil)
        model.updateValue("192.168.1.1")

        XCTAssertEqual(model.scenario, .ip)
        XCTAssertEqual(model.ruleType, .ipCIDR)
        XCTAssertEqual(model.availableTypes, [.ipCIDR])
        let rule = model.commitRule()
        XCTAssertEqual(rule?.type, .ipCIDR)
        XCTAssertEqual(rule?.value, "192.168.1.1/32")
    }

    func testIPScenarioFlipsBackToDomainOnHostInput() {
        var model = form(capturing: "http://192.168.1.1/")
        model.updateValue("example.com")

        XCTAssertEqual(model.scenario, .domain)
        XCTAssertEqual(model.ruleType, .domainSuffix)
        let rule = model.commitRule()
        XCTAssertEqual(rule?.type, .domainSuffix)
        XCTAssertEqual(rule?.value, "example.com")
    }

    func testIDNInputNormalizesToPunycode() {
        // VAL-QUICKADD-020: IDN hosts save their ACE (punycode) form.
        var model = form(capturing: "https://BÜCHER.de/kaufen")

        XCTAssertEqual(model.value, "xn--bcher-kva.de")
        let rule = model.commitRule()
        XCTAssertEqual(rule?.type, .domainSuffix)
        XCTAssertEqual(rule?.value, "xn--bcher-kva.de")
    }

    func testLongHostSavesComplete() {
        // VAL-QUICKADD-020: a long-but-legal host is saved in full (display
        // truncation is a view concern).
        let label = String(repeating: "a", count: 60)
        var model = form(capturing: nil)
        model.updateValue("\(label).example.com")

        XCTAssertEqual(model.commitRule()?.value, "\(label).example.com")
    }

    // MARK: - Validation

    func testInvalidInputBlocksSaveWithReadableMessage() {
        // VAL-QUICKADD-008: illegal strings block saving with per-category
        // copy; none of them ever commit.
        let cases: [(input: String, fragment: String)] = [
            ("not a url", "不是合法的域名或 IP 地址"),
            ("about:blank", "无法识别的地址格式"),
            ("chrome://settings", "不支持「chrome」链接"),
            ("192.168.1", "不是合法的域名或 IP 地址"),
            ("   ", "请输入匹配值"),
        ]
        for (input, fragment) in cases {
            var model = form(capturing: nil)
            model.updateValue(input)
            let problem = model.validationProblem
            XCTAssertNotNil(problem, "expected a problem for \(input)")
            XCTAssertTrue(
                problem?.contains(fragment) == true,
                "problem for \(input) was \(problem ?? "nil")"
            )
            XCTAssertNil(model.commitRule(), "commit must be blocked for \(input)")
        }
    }

    func testInvalidIntermediateInputKeepsScenarioSticky() {
        // Deleting the last octet mid-edit must not bounce the type controls
        // around; the scenario only moves on a successful parse.
        var model = form(capturing: "http://192.168.1.1/")
        model.updateValue("192.168.1.")

        XCTAssertEqual(model.scenario, .ip)
        XCTAssertEqual(model.ruleType, .ipCIDR)
        XCTAssertNotNil(model.validationProblem)
    }

    func testEmptyTargetBlocksSave() {
        var model = form(capturing: "https://www.example.com/")
        model.targetTag = "  "

        XCTAssertEqual(model.validationProblem, "请选择出站目标")
        XCTAssertNil(model.commitRule())
    }

    // MARK: - Commit

    func testCommitIsIdempotent() {
        // VAL-QUICKADD-011: only the first commit yields a rule — a repeated
        // Return press can never insert twice.
        var model = form(capturing: "https://www.example.com/")

        XCTAssertNotNil(model.commitRule())
        XCTAssertTrue(model.isCommitted)
        XCTAssertNil(model.commitRule())
    }

    func testCommitCarriesTheChosenTarget() {
        // VAL-QUICKADD-004 (model side): the picked outbound tag — including
        // reject — lands verbatim on the saved rule.
        var model = form(capturing: "https://www.example.com/")
        model.targetTag = "reject"

        XCTAssertEqual(model.commitRule()?.target, "reject")
    }

    func testKeywordCommitSavesDomainKeywordRule() {
        // VAL-QUICKADD-017: the keyword candidate saves as DOMAIN-KEYWORD.
        var model = form(capturing: "https://www.example.com/")
        model.selectCandidate(DomainCandidate(kind: .keyword, value: "example"))

        let rule = model.commitRule()
        XCTAssertEqual(rule?.type, .domainKeyword)
        XCTAssertEqual(rule?.value, "example")
    }

    func testExactHostCommitSavesDomainRule() {
        // VAL-QUICKADD-003: the exact-host candidate saves as DOMAIN.
        var model = form(capturing: "https://www.example.com/")
        model.selectType(.domain)

        let rule = model.commitRule()
        XCTAssertEqual(rule?.type, .domain)
        XCTAssertEqual(rule?.value, "www.example.com")
    }

    func testCommittedRuleIsEnabledLeaf() {
        var model = form(capturing: "https://www.example.com/")

        let rule = model.commitRule()
        XCTAssertEqual(rule?.isEnabled, true)
        XCTAssertEqual(rule?.subRules, [])
    }

    // MARK: - Window-session integration

    func testRebuiltFormCarriesNoResidueFromAPreviousSession() {
        // VAL-QUICKADD-010 (model side): the view rebuilds the model from
        // every fresh capture outcome; nothing from the previous session —
        // edited value, retargeted tag, committed flag — survives into it.
        var previous = form(capturing: "https://old.example.com/")
        previous.updateValue("edited.example.com")
        previous.targetTag = "direct"
        XCTAssertNotNil(previous.commitRule())

        let rebuilt = form(capturing: "https://www.example.com/")

        XCTAssertEqual(rebuilt.value, "example.com")
        XCTAssertEqual(rebuilt.ruleType, .domainSuffix)
        XCTAssertEqual(rebuilt.targetTag, proxy)
        XCTAssertFalse(rebuilt.isCommitted)
        XCTAssertNil(rebuilt.prefillProblem)
    }

    func testTwoIndependentSessionsCommitEquivalentRulesWithDistinctIdentities() {
        // VAL-QUICKADD-014 (model side): each window session mints a fresh
        // rule id, so adding the same page twice yields two coexisting,
        // equivalent rules rather than a collision.
        var first = form(capturing: "https://www.example.com/")
        var second = form(capturing: "https://www.example.com/")

        let a = first.commitRule()
        let b = second.commitRule()

        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a?.id, b?.id)
        XCTAssertEqual(a?.type, b?.type)
        XCTAssertEqual(a?.value, b?.value)
        XCTAssertEqual(a?.target, b?.target)
    }

    func testCommitCarriesADriftedTargetTagVerbatim() {
        // VAL-QUICKADD-013 (model side): the form only requires a non-empty
        // target, so a group deleted after being picked still saves verbatim
        // — flagging it unresolved is the rule list's concern, and skipping
        // it at generation is the config builder's.
        var model = form(capturing: "https://www.example.com/")
        model.targetTag = "工作"

        XCTAssertNil(model.validationProblem)
        XCTAssertEqual(model.commitRule()?.target, "工作")
    }
}
