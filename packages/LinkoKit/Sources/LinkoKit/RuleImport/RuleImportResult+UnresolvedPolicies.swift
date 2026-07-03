import Foundation

extension RuleImportResult {
    /// Referenced policy names that resolve to nothing the caller knows about:
    /// not an existing node/group/builtin tag (exact match) and not any
    /// spelling of the built-in reject action, which the engine resolves
    /// case-insensitively across the Surge variants (REJECT-DROP /
    /// REJECT-TINYGIF / REJECT-NO-DROP).
    ///
    /// This is the single counting predicate behind the import preview's
    /// "策略名未匹配" list, shared by the Surge and Clash channels so a pasted
    /// `DOMAIN,ads.example.com,REJECT` never asks the user to re-target it.
    public func unresolvedPolicies(existingTags: Set<String>) -> [String] {
        referencedPolicies.filter {
            !existingTags.contains($0) && !BuiltinReject.matches($0)
        }
    }
}
