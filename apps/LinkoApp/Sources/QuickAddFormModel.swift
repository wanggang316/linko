import Foundation
import LinkoKit

/// Pure state model behind the quick-add rule form: the candidate scopes
/// parsed from the captured page, the deliberately narrow rule-type choice,
/// the editable matcher value, and the outbound target. UI-free so the
/// candidate/type pairing, normalization, and validation logic stay
/// unit-testable; `QuickAddRuleView` renders it and forwards control events.
///
/// Invariants:
/// - `ruleType` always sits inside `availableTypes` for the current scenario.
/// - Type and value move as a pair: picking a candidate updates both, and
///   switching the type re-derives the value from that type's candidate when
///   one exists (otherwise the current value stays editable; empty blocks
///   saving).
/// - Every save goes through `DomainCandidateParser`, so persisted values are
///   trimmed, lowercased, punycode-encoded hostnames or canonical CIDR
///   literals — never raw URL fragments. The captured URL itself is never
///   logged (see the privacy contract on `BrowserPageReadError`).
struct QuickAddFormModel: Equatable {

    /// Which rule family the form currently edits. Tracks the value: a legal
    /// IP literal flips into the IP scenario (whose only type is IP-CIDR); a
    /// hostname flips back to the domain scenario.
    enum Scenario: Equatable {
        case domain
        case ip
    }

    /// Candidates derived from the captured page URL, in the parser's fixed
    /// presentation order. Empty in manual mode; never regenerated from
    /// manual edits (chips stay tied to the capture).
    let candidates: [DomainCandidate]
    /// Shown when a captured URL yielded no candidates and the form fell back
    /// to manual input; `nil` for a clean prefill or a plain manual open.
    let prefillProblem: String?
    private(set) var scenario: Scenario
    private(set) var ruleType: RuleType
    private(set) var value: String
    /// The outbound tag the saved rule routes to. Defaults to
    /// `RoutingTargets.defaultTag` (the "proxy" group when present) — never
    /// reject.
    var targetTag: String
    /// Flips on the first successful `commitRule()`; later commits return
    /// `nil`, so a repeated Return press can never insert a second rule.
    private(set) var isCommitted = false

    /// Builds the form from a capture outcome. `capturedInput` is the
    /// captured page URL (`nil` when the window opened straight into manual
    /// mode); an unparseable capture falls back to manual mode with
    /// `prefillProblem` explaining why.
    init(capturedInput: String?, defaultTarget: String) {
        self.targetTag = defaultTarget
        guard let capturedInput else {
            self.candidates = []
            self.prefillProblem = nil
            self.scenario = .domain
            self.ruleType = .domainSuffix
            self.value = ""
            return
        }
        switch DomainCandidateParser().parse(capturedInput) {
        case .success(let outcome):
            let preselected = outcome.defaultCandidate
            self.candidates = outcome.candidates
            self.prefillProblem = nil
            self.scenario = preselected.kind == .ipCIDR ? .ip : .domain
            self.ruleType = preselected.ruleType
            self.value = preselected.value
        case .failure:
            self.candidates = []
            self.prefillProblem = "未能从当前页面地址提取域名或 IP，请手动输入。"
            self.scenario = .domain
            self.ruleType = .domainSuffix
            self.value = ""
        }
    }

    // MARK: - Derived state

    /// The closed type range the form offers: the three domain matchers, or
    /// just IP-CIDR in the IP scenario. Deliberately excludes final/logical/
    /// process/… kinds — those belong to the full rule editor.
    var availableTypes: [RuleType] {
        scenario == .ip ? [.ipCIDR] : [.domainSuffix, .domain, .domainKeyword]
    }

    /// The candidate the current type/value pair matches, or `nil` after a
    /// manual edit diverged from every candidate.
    var selectedCandidate: DomainCandidate? {
        candidates.first { $0.ruleType == ruleType && $0.value == value }
    }

    /// A short Chinese description of the first blocking problem, or `nil`
    /// when the form is savable. Mirrors the copy style of `RuleEditorView`.
    var validationProblem: String? {
        if targetTag.trimmingCharacters(in: .whitespaces).isEmpty {
            return "请选择出站目标"
        }
        switch DomainCandidateParser().parse(value) {
        case .success:
            return nil
        case .failure(let error):
            return Self.problemDescription(for: error)
        }
    }

    // MARK: - Events

    /// Picks a parsed candidate: type and value update together to that
    /// candidate's kind and value.
    mutating func selectCandidate(_ candidate: DomainCandidate) {
        guard candidates.contains(candidate) else { return }
        scenario = candidate.kind == .ipCIDR ? .ip : .domain
        ruleType = candidate.ruleType
        value = candidate.value
    }

    /// Switches the rule type directly (without going through a candidate).
    /// The value re-derives from that type's candidate when one exists; a
    /// type with no candidate (e.g. a short label suppressed the keyword)
    /// keeps the current value editable.
    mutating func selectType(_ type: RuleType) {
        guard availableTypes.contains(type), type != ruleType else { return }
        ruleType = type
        if let match = candidates.first(where: { $0.ruleType == type }) {
            value = match.value
        }
    }

    /// Applies a manual edit. The scenario tracks the value live: a complete
    /// IP literal flips to IP-CIDR, a hostname flips back to the domain
    /// scenario (restoring the default suffix type when the IP type became
    /// stale). Invalid intermediate input leaves scenario and type untouched —
    /// saving is blocked by `validationProblem` until it parses.
    mutating func updateValue(_ raw: String) {
        value = raw
        switch DomainCandidateParser().parse(raw) {
        case .success(.ip):
            scenario = .ip
            ruleType = .ipCIDR
        case .success(.domain):
            scenario = .domain
            if ruleType == .ipCIDR {
                ruleType = .domainSuffix
            }
        case .failure:
            break
        }
    }

    // MARK: - Commit

    /// Normalizes the current type/value pair into the rule the save pipeline
    /// persists, or `nil` when validation blocks saving or a rule was already
    /// committed (idempotence guard). The value is re-parsed so manual edits
    /// land trimmed/lowercased/punycode-encoded; a whole pasted URL reduces
    /// to its hostname, and a legal IP saves as an IP-CIDR rule regardless of
    /// the displayed domain type.
    mutating func commitRule() -> RoutingRule? {
        guard !isCommitted, validationProblem == nil,
              case .success(let outcome) = DomainCandidateParser().parse(value)
        else { return nil }
        isCommitted = true
        switch outcome {
        case .ip(let candidate):
            return RoutingRule(type: .ipCIDR, value: candidate.value, target: targetTag)
        case .domain(let list):
            // Defensive: a stale IP type paired with a hostname value falls
            // back to the outcome's default kind; `updateValue` normally
            // flips the type before this can happen.
            let type = ruleType == .ipCIDR ? list[0].ruleType : ruleType
            return RoutingRule(type: type, value: Self.fullHost(of: list), target: targetTag)
        }
    }

    // MARK: - Helpers

    /// The full normalized ASCII hostname carried by a domain outcome: the
    /// exact-host candidate when present, else the first candidate's value
    /// (which equals the full host when the host IS the registrable domain,
    /// and for single-label hosts). Internal: `QuickAddRuleView.displayHost`
    /// reuses it so the captured-host header and the saved value can never
    /// disagree about what "the host" of a capture is.
    static func fullHost(of candidates: [DomainCandidate]) -> String {
        candidates.first { $0.kind == .host }?.value ?? candidates[0].value
    }

    /// Maps a parser failure onto user-facing copy. Error payloads carry only
    /// static categories (never input fragments), so the messages stay
    /// generic by construction.
    private static func problemDescription(for error: DomainCandidateError) -> String {
        switch error {
        case .emptyInput:
            return "请输入匹配值"
        case .unsupportedScheme(let scheme):
            return "不支持「\(scheme)」链接，请输入 http(s) 网址、域名或 IP"
        case .missingHost:
            return "网址中缺少主机名，请输入域名或 IP"
        case .malformedAuthority:
            return "无法识别的地址格式，请输入域名或 IP"
        case .invalidHost:
            return "不是合法的域名或 IP 地址"
        }
    }
}
