import Foundation

/// Shared parser for the comma-separated rule grammar used by both Surge
/// `[Rule]` lines and Clash `rules:` list items:
///
///     TYPE,VALUE,POLICY[,option][,option]...
///     FINAL,POLICY[,option]
///     GEOIP,CN,DIRECT,no-resolve
///     MATCH,Proxy            (Clash catch-all alias for FINAL)
///
/// The parser only concerns itself with turning one logical rule line into a
/// `RoutingRule` (or recording a warning). Format-specific framing — section
/// headers, `//` comments, YAML `- ` list markers, quoting — is stripped by the
/// individual importers before a line reaches here.
struct RuleLineParser {
    /// Outcome of parsing a single rule line.
    enum Outcome {
        /// A successfully parsed rule plus the policy/outbound name it targets.
        case rule(RoutingRule, policy: String)
        /// The line names a recognised type but could not be fully mapped (e.g.
        /// missing value or policy); carries a user-facing warning.
        case warning(String)
        /// The line is blank/comment-only after framing was stripped; ignore it.
        case empty
    }

    /// Aliases accepted in the type position that are not themselves `RuleType`
    /// raw values. Each maps to a canonical `RuleType`.
    ///
    /// - `MATCH` is Clash's catch-all, equivalent to Surge `FINAL`.
    /// - `IP-CIDR6` is its own `RuleType` but several profiles also write the
    ///   IPv6 form as `IP6-CIDR`; both resolve to `.ipCIDR6`.
    /// - `DST-PORT` / `IN-PORT` are alternate spellings seen in the wild.
    private static let typeAliases: [String: RuleType] = [
        "MATCH": .final,
        "IP6-CIDR": .ipCIDR6,
        "DST-PORT": .destPort,
        "GEOSITE-": .geosite
    ]

    /// Rule-option tokens that may trail the policy and carry no payload.
    /// They are stripped (and `no-resolve` is preserved structurally only by
    /// being ignored — sing-box resolves lazily) so they never corrupt the
    /// policy name.
    private static let knownOptions: Set<String> = [
        "no-resolve",
        "force-remote-dns",
        "pre-matching",
        "extended-matching",
        "dns-failed"
    ]

    /// Parses a single, already-de-framed rule line.
    ///
    /// - Parameter line: a rule body such as `DOMAIN-SUFFIX,google.com,Proxy`.
    ///   Must not contain comment markers or list prefixes.
    func parse(_ line: String) -> Outcome {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }

        // Split on commas and trim each field; drop a trailing empty field that
        // results from a dangling comma.
        var fields = trimmed
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = fields.last, last.isEmpty { fields.removeLast() }
        guard let rawType = fields.first, !rawType.isEmpty else { return .empty }

        guard let type = Self.resolveType(rawType) else {
            return .warning("Skipped unsupported rule type \"\(rawType)\": \(trimmed)")
        }

        // FINAL / MATCH: `FINAL,POLICY[,options]` — no value field.
        if type.isFinal {
            let rest = Array(fields.dropFirst())
            let (policy, _) = Self.extractPolicyAndOptions(from: rest, hasValue: false)
            guard let policy, !policy.isEmpty else {
                return .warning("Skipped FINAL rule without a policy: \(trimmed)")
            }
            return .rule(RoutingRule(type: .final, value: "", target: policy), policy: policy)
        }

        // Logical AND/OR/NOT in the comma grammar are not representable as a
        // flat line; Surge/Clash express them with nested parentheses we do not
        // attempt to parse. Skip with a clear warning rather than mis-map.
        if type.isLogical {
            return .warning("Skipped logical rule (\(rawType)); nested rules are not imported: \(trimmed)")
        }

        // Leaf rule: TYPE,VALUE,POLICY[,options]
        let afterType = Array(fields.dropFirst())
        guard let value = afterType.first, !value.isEmpty else {
            return .warning("Skipped \(rawType) rule without a value: \(trimmed)")
        }
        let rest = Array(afterType.dropFirst())
        let (policy, _) = Self.extractPolicyAndOptions(from: rest, hasValue: true)
        guard let policy, !policy.isEmpty else {
            return .warning("Skipped \(rawType) rule without a policy: \(trimmed)")
        }

        return .rule(RoutingRule(type: type, value: value, target: policy), policy: policy)
    }

    /// Resolves a raw type token (case-insensitive) to a `RuleType`, honouring
    /// the alias table.
    private static func resolveType(_ raw: String) -> RuleType? {
        let upper = raw.uppercased()
        if let direct = RuleType(rawValue: upper) { return direct }
        return typeAliases[upper]
    }

    /// From the fields following the value (or following the type, for FINAL),
    /// returns the policy name and the recognised trailing options.
    ///
    /// The first non-option field is the policy; any further fields that are
    /// known option tokens are collected as options. An unknown trailing field
    /// after the policy is tolerated and ignored (some profiles append vendor
    /// flags) so it never leaks into the policy name.
    private static func extractPolicyAndOptions(
        from fields: [String],
        hasValue: Bool
    ) -> (policy: String?, options: [String]) {
        var policy: String?
        var options: [String] = []
        for field in fields where !field.isEmpty {
            if policy == nil && !knownOptions.contains(field.lowercased()) {
                policy = field
            } else if knownOptions.contains(field.lowercased()) {
                options.append(field.lowercased())
            }
            // else: an extra non-option field after the policy — ignore.
        }
        return (policy, options)
    }
}
