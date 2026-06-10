import Foundation
import Yams

/// Imports a Clash `rules:` list into `RoutingRule`s.
///
/// Accepts either a full Clash YAML document (the `rules:` array is extracted)
/// or a bare YAML list of rule items (`- DOMAIN-SUFFIX,google.com,Proxy`). When
/// the input is not parseable as YAML it degrades to a line-based reader so a
/// hand-pasted snippet without perfect indentation still imports.
///
/// Clash's `MATCH` catch-all is mapped to `FINAL`; option tokens such as
/// `no-resolve` are recorded and dropped; unsupported types are skipped with a
/// warning. Policy names are carried through as `target`s and collected in
/// first-seen order in `referencedPolicies`.
public struct ClashRuleImporter: RuleImporting {
    private let lineParser = RuleLineParser()

    public init() {}

    /// Clash callers may also hold this type; delegate Surge text to the Surge
    /// importer for convenience.
    public func importSurgeRules(_ text: String) -> RuleImportResult {
        SurgeRuleImporter().importSurgeRules(text)
    }

    public func importClashRules(_ text: String) -> RuleImportResult {
        let ruleItems = Self.extractRuleItems(from: text)

        var rules: [RoutingRule] = []
        var policies: [String] = []
        var seenPolicies: Set<String> = []
        var warnings: [String] = []

        for item in ruleItems {
            switch lineParser.parse(item) {
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

    // MARK: - Extraction

    /// Returns the individual rule strings from `text`.
    ///
    /// A structured YAML parse is authoritative: if `text` is valid YAML, the
    /// rule list comes from its `rules:` key (or the root list) and the line
    /// fallback is never used — a valid document that simply has no `rules:`
    /// key yields no rules rather than mis-reading config keys as rules. The
    /// line fallback runs only when `text` is not valid YAML at all (e.g. a
    /// hand-pasted snippet with broken indentation).
    private static func extractRuleItems(from text: String) -> [String] {
        switch ruleItemsViaYAML(text) {
        case .parsed(let items):
            return items
        case .notYAML:
            return ruleItemsViaLines(text)
        }
    }

    private enum YAMLExtraction {
        /// `text` parsed as YAML; carries the (possibly empty) rule list.
        case parsed([String])
        /// `text` is not valid YAML — caller should use the line fallback.
        case notYAML
    }

    /// Parses `text` as YAML and pulls a `[String]` from a top-level `rules:`
    /// key or, if the document is itself a list, from the root.
    private static func ruleItemsViaYAML(_ text: String) -> YAMLExtraction {
        let root: Any?
        do {
            root = try Yams.load(yaml: text)
        } catch {
            return .notYAML
        }

        // A bare scalar (e.g. a single `DOMAIN,host,Proxy` line) is technically
        // valid YAML but carries no list structure; defer to the line reader.
        let rawList: [Any]?
        if let dict = root as? [AnyHashable: Any] {
            rawList = dict["rules"] as? [Any]
        } else if let list = root as? [Any] {
            rawList = list
        } else {
            return .notYAML
        }

        guard let rawList else {
            // Valid mapping document without a `rules:` key -> no rules.
            return .parsed([])
        }
        let items = rawList.compactMap { element -> String? in
            if let s = element as? String { return s }
            // A YAML item parsed into a non-string scalar by some emitters;
            // stringify defensively.
            return String(describing: element)
        }
        return .parsed(items)
    }

    /// Line-based fallback: strips an optional `rules:` header, leading `- `
    /// list markers, surrounding quotes, and `#` comments.
    private static func ruleItemsViaLines(_ text: String) -> [String] {
        var items: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.caseInsensitiveCompare("rules:") == .orderedSame { continue }
            if line.hasPrefix("- ") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line == "-" {
                continue
            }
            line = Self.unquote(line)
            // Strip a trailing `#` comment that survived (outside of quotes).
            if let hash = line.range(of: "#") {
                line = String(line[line.startIndex..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty { items.append(line) }
        }
        return items
    }

    /// Removes a single pair of surrounding single or double quotes.
    private static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
