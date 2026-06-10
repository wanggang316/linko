import Foundation

/// Imports the `[Rule]` section of a Surge profile into `RoutingRule`s.
///
/// Accepts either a full Surge profile (in which case only the lines inside the
/// `[Rule]` section are read) or a bare list of rule lines (no `[Rule]` header).
/// Surge inline `//` comments and full-line `#` comments are stripped; rule
/// options such as `no-resolve` / `extended-matching` are recorded and dropped;
/// unsupported rule types are skipped with a warning.
///
/// Policy names are carried through verbatim as each rule's `target` and are
/// collected (first-seen order) in `referencedPolicies`; the caller resolves
/// them to node/group tags by name.
public struct SurgeRuleImporter: RuleImporting {
    private let lineParser = RuleLineParser()

    public init() {}

    public func importSurgeRules(_ text: String) -> RuleImportResult {
        let lines = text.components(separatedBy: .newlines)

        // When a `[Rule]` header is present anywhere, parse only the lines of
        // that section. Otherwise treat the whole input as rule lines.
        let hasSectionHeaders = lines.contains { Self.sectionName(of: $0) != nil }
        let ruleLines: [String] = hasSectionHeaders
            ? Self.extractRuleSection(from: lines)
            : lines

        var rules: [RoutingRule] = []
        var policies: [String] = []
        var seenPolicies: Set<String> = []
        var warnings: [String] = []

        for rawLine in ruleLines {
            let stripped = Self.stripComments(rawLine)
            guard !stripped.isEmpty else { continue }

            switch lineParser.parse(stripped) {
            case .empty:
                continue
            case let .warning(message):
                warnings.append(message)
            case let .rule(rule, policy):
                rules.append(rule)
                if seenPolicies.insert(policy).inserted {
                    policies.append(policy)
                }
            }
        }

        return RuleImportResult(rules: rules, referencedPolicies: policies, warnings: warnings)
    }

    /// Clash entry point delegates to the dedicated Clash importer so callers
    /// holding a `SurgeRuleImporter` can still migrate Clash rules.
    public func importClashRules(_ text: String) -> RuleImportResult {
        ClashRuleImporter().importClashRules(text)
    }

    // MARK: - Section handling

    /// Returns the lines belonging to the `[Rule]` section: everything between
    /// the `[Rule]` header and the next `[Section]` header (or end of file).
    private static func extractRuleSection(from lines: [String]) -> [String] {
        var collected: [String] = []
        var inRuleSection = false
        for line in lines {
            if let section = sectionName(of: line) {
                inRuleSection = (section.caseInsensitiveCompare("Rule") == .orderedSame)
                continue
            }
            if inRuleSection { collected.append(line) }
        }
        return collected
    }

    /// If `line` is a section header like `[Rule]`, returns the inner name
    /// (`Rule`); otherwise `nil`.
    private static func sectionName(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 3 else {
            return nil
        }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }

    /// Removes a trailing `//` inline comment and full-line `#`/`;` comments,
    /// returning the trimmed rule body (possibly empty).
    ///
    /// A `//` only starts a comment when it is preceded by whitespace (or sits
    /// at the start of the line). This preserves the `//` inside URL schemes
    /// such as `https://example.com/list` that appear in `RULE-SET` values,
    /// where Surge writes inline notes as ` // ...` with a leading space.
    private static func stripComments(_ line: String) -> String {
        let body = Self.stripInlineSlashComment(line)
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { return "" }
        return trimmed
    }

    /// Truncates `line` at the first `//` that is at the line start or preceded
    /// by a whitespace character.
    private static func stripInlineSlashComment(_ line: String) -> String {
        let chars = Array(line)
        var i = 0
        while i + 1 < chars.count {
            if chars[i] == "/" && chars[i + 1] == "/" {
                let precededBySpace = (i == 0) || chars[i - 1].isWhitespace
                if precededBySpace {
                    return String(chars[0..<i])
                }
            }
            i += 1
        }
        return line
    }
}
