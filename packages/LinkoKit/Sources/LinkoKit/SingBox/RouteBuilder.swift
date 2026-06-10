import Foundation

/// Builds the policy-group outbounds (`selector`/`urltest`), the `route` block
/// (`rules`, `rule_set`, `final`, `auto_detect_interface`), and surfaces the set
/// of warnings produced while resolving rule/group targets.
///
/// Field names verified against:
/// - https://sing-box.sagernet.org/configuration/route/
/// - https://sing-box.sagernet.org/configuration/route/rule/
/// - https://sing-box.sagernet.org/configuration/rule-set/
/// - https://sing-box.sagernet.org/configuration/outbound/selector/
/// - https://sing-box.sagernet.org/configuration/outbound/urltest/
struct RouteBuilder {
    /// The default probe URL applied to urltest groups that don't set one.
    static let defaultTestURL = "https://www.gstatic.com/generate_204"
    /// The default urltest probe interval.
    static let defaultInterval = "3m"

    /// The result of compiling the routing layer: the group outbound objects to
    /// append to `outbounds`, the assembled `route` object, and any soft
    /// warnings (dropped rules, degraded groups).
    struct Result {
        var groupOutbounds: [[String: Any]]
        var route: [String: Any]
        var warnings: [String]
    }

    private let routing: RoutingConfig
    /// All outbound tags that a rule/group/final may legitimately target:
    /// node tags + group names + reserved built-ins ("direct"/"proxy").
    private let resolvableTags: Set<String>
    private let groupNames: Set<String>
    private let ruleSetTags: Set<String>

    init(routing: RoutingConfig, nodeTags: [String]) {
        self.routing = routing
        self.groupNames = Set(routing.groups.map(\.name))
        self.ruleSetTags = Set(routing.ruleSets.map(\.tag))
        var resolvable = Set(nodeTags)
        resolvable.formUnion(groupNames)
        resolvable.insert("direct")
        // "proxy" is always resolvable: either a user group named it, or the
        // builder synthesizes the legacy selector under that name.
        resolvable.insert(PolicyGroup.defaultGroupName)
        self.resolvableTags = resolvable
    }

    /// Compiles groups + rules + rule_set + final into a `Result`.
    func build(nodeTags: [String], selectedTag: String?) -> Result {
        var warnings: [String] = []
        let groupOutbounds = buildGroupOutbounds(nodeTags: nodeTags, selectedTag: selectedTag, warnings: &warnings)
        var route: [String: Any] = [:]

        // rule_set entries are emitted only when at least one rule (route or
        // DNS) references them, but we keep them whenever declared so the user's
        // managed sets are available; reference validation is a soft warning.
        let ruleSetObjects = routing.ruleSets.map(ruleSetObject(for:))
        if !ruleSetObjects.isEmpty {
            route["rule_set"] = ruleSetObjects
        }

        let ruleObjects = buildRuleObjects(warnings: &warnings)
        if !ruleObjects.isEmpty {
            route["rules"] = ruleObjects
        }

        route["final"] = resolveFinalTarget(warnings: &warnings)

        if routing.autoDetectInterface {
            route["auto_detect_interface"] = true
        }

        return Result(groupOutbounds: groupOutbounds, route: route, warnings: warnings)
    }

    // MARK: - Final

    private func resolveFinalTarget(warnings: inout [String]) -> String {
        let target = routing.finalTarget
        if resolvableTags.contains(target) {
            return target
        }
        warnings.append("route.final 目标 “\(target)” 未找到，已回退到 “\(PolicyGroup.defaultGroupName)”。")
        return PolicyGroup.defaultGroupName
    }

    // MARK: - Groups

    private func buildGroupOutbounds(nodeTags: [String], selectedTag: String?, warnings: inout [String]) -> [[String: Any]] {
        routing.groups.map { group in
            groupOutbound(group, nodeTags: nodeTags, selectedTag: selectedTag, warnings: &warnings)
        }
    }

    private func groupOutbound(_ group: PolicyGroup, nodeTags: [String], selectedTag: String?, warnings: inout [String]) -> [String: Any] {
        var members = resolvedMemberTags(group, nodeTags: nodeTags, warnings: &warnings)
        // A group must reference at least one outbound; fall back to "direct" so
        // sing-box accepts the config rather than failing to start.
        if members.isEmpty {
            warnings.append("策略组 “\(group.name)” 没有有效成员，已退回到 “direct”。")
            members = ["direct"]
        }

        var outbound: [String: Any] = [
            "type": group.type.singBoxOutboundType,
            "tag": group.name,
            "outbounds": members,
        ]

        switch group.type {
        case .select:
            // Track the selected node as the group's default member when it is a
            // member of the default group, mirroring legacy selector behavior.
            if group.name == PolicyGroup.defaultGroupName,
               let selectedTag, members.contains(selectedTag) {
                outbound["default"] = selectedTag
            }

        case .urlTest:
            applyURLTestParameters(group, into: &outbound)

        case .fallback:
            warnings.append("策略组 “\(group.name)” 的 fallback 类型在 sing-box 中没有原生支持，已降级为 url-test。")
            applyURLTestParameters(group, into: &outbound)

        case .loadBalance:
            warnings.append("策略组 “\(group.name)” 的 load-balance 类型在 sing-box 中没有原生支持，已降级为 url-test。")
            applyURLTestParameters(group, into: &outbound)
        }

        return outbound
    }

    private func applyURLTestParameters(_ group: PolicyGroup, into outbound: inout [String: Any]) {
        outbound["url"] = group.testURL.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultTestURL
        outbound["interval"] = group.interval.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultInterval
        if let tolerance = group.tolerance {
            outbound["tolerance"] = tolerance
        }
    }

    private func resolvedMemberTags(_ group: PolicyGroup, nodeTags: [String], warnings: inout [String]) -> [String] {
        var tags: [String] = []
        for member in group.members {
            switch member.kind {
            case .node, .builtin:
                if member.kind == .builtin {
                    // Built-ins ("direct"/"proxy") and any node tag are accepted.
                    tags.append(member.tag)
                } else if nodeTags.contains(member.tag) {
                    tags.append(member.tag)
                } else {
                    warnings.append("策略组 “\(group.name)” 引用了未知节点 “\(member.tag)”，已跳过。")
                }
            case .group:
                if groupNames.contains(member.tag), member.tag != group.name {
                    tags.append(member.tag)
                } else if member.tag == group.name {
                    warnings.append("策略组 “\(group.name)” 不能把自己作为成员，已跳过。")
                } else {
                    warnings.append("策略组 “\(group.name)” 引用了未知策略组 “\(member.tag)”，已跳过。")
                }
            }
        }
        return tags
    }

    // MARK: - Rules

    private func buildRuleObjects(warnings: inout [String]) -> [[String: Any]] {
        var objects: [[String: Any]] = []
        for rule in routing.rules where rule.isEnabled {
            // FINAL rules are folded into route.final, not emitted as list entries.
            guard !rule.type.isFinal else { continue }
            guard let object = ruleObject(for: rule, warnings: &warnings) else { continue }
            objects.append(object)
        }
        return objects
    }

    /// Compiles a single rule into a `route.rules` entry with an explicit
    /// `{action:"route", outbound:<target>}` (sing-box 1.11+).
    private func ruleObject(for rule: RoutingRule, warnings: inout [String]) -> [String: Any]? {
        guard resolvableTags.contains(rule.target) else {
            warnings.append("规则目标 “\(rule.target)” 未找到，规则已跳过。")
            return nil
        }

        guard var matcher = matcherObject(for: rule, warnings: &warnings) else { return nil }
        matcher["action"] = "route"
        matcher["outbound"] = rule.target
        return matcher
    }

    /// Builds the match portion of a rule (no action). Returns `nil` when the
    /// rule cannot be represented (empty value, empty logical, etc.).
    private func matcherObject(for rule: RoutingRule, warnings: inout [String]) -> [String: Any]? {
        if rule.type.isLogical {
            return logicalMatcher(for: rule, warnings: &warnings)
        }

        let values = splitValues(rule.value)

        switch rule.type {
        case .domain:
            return leafMatcher(field: "domain", values: values, rule: rule, warnings: &warnings)
        case .domainSuffix:
            return leafMatcher(field: "domain_suffix", values: values, rule: rule, warnings: &warnings)
        case .domainKeyword:
            return leafMatcher(field: "domain_keyword", values: values, rule: rule, warnings: &warnings)
        case .domainRegex:
            return leafMatcher(field: "domain_regex", values: values, rule: rule, warnings: &warnings)
        case .ipCIDR, .ipCIDR6:
            return leafMatcher(field: "ip_cidr", values: values, rule: rule, warnings: &warnings)
        case .srcIPCIDR:
            return leafMatcher(field: "source_ip_cidr", values: values, rule: rule, warnings: &warnings)
        case .processName:
            return leafMatcher(field: "process_name", values: values, rule: rule, warnings: &warnings)
        case .processPath:
            return leafMatcher(field: "process_path", values: values, rule: rule, warnings: &warnings)
        case .network:
            return leafMatcher(field: "network", values: values.map { $0.lowercased() }, rule: rule, warnings: &warnings)
        case .protocolSniff:
            return leafMatcher(field: "protocol", values: values.map { $0.lowercased() }, rule: rule, warnings: &warnings)
        case .port, .destPort:
            return portMatcher(field: "port", values: values, rule: rule, warnings: &warnings)
        case .srcPort:
            return portMatcher(field: "source_port", values: values, rule: rule, warnings: &warnings)
        case .geoip, .geosite, .ruleSet:
            return ruleSetMatcher(values: values, rule: rule, warnings: &warnings)
        case .and, .or, .not, .final:
            return nil // handled above / not a list entry
        }
    }

    private func leafMatcher(field: String, values: [String], rule: RoutingRule, warnings: inout [String]) -> [String: Any]? {
        guard !values.isEmpty else {
            warnings.append("规则 \(rule.type.rawValue) 的值为空，已跳过。")
            return nil
        }
        return [field: values]
    }

    private func portMatcher(field: String, values: [String], rule: RoutingRule, warnings: inout [String]) -> [String: Any]? {
        let ports = values.compactMap { Int($0) }
        guard !ports.isEmpty else {
            warnings.append("规则 \(rule.type.rawValue) 的端口值无效，已跳过。")
            return nil
        }
        return [field: ports]
    }

    private func ruleSetMatcher(values: [String], rule: RoutingRule, warnings: inout [String]) -> [String: Any]? {
        guard !values.isEmpty else {
            warnings.append("规则 \(rule.type.rawValue) 未指定规则集标签，已跳过。")
            return nil
        }
        for tag in values where !ruleSetTags.contains(tag) {
            warnings.append("规则 \(rule.type.rawValue) 引用了未定义的规则集 “\(tag)”，请确认已在规则集列表中添加。")
        }
        return ["rule_set": values]
    }

    private func logicalMatcher(for rule: RoutingRule, warnings: inout [String]) -> [String: Any]? {
        let subObjects = rule.subRules
            .filter(\.isEnabled)
            .compactMap { matcherObject(for: $0, warnings: &warnings) }
        guard !subObjects.isEmpty else {
            warnings.append("逻辑规则 \(rule.type.rawValue) 没有有效的子规则，已跳过。")
            return nil
        }
        var object: [String: Any] = [
            "type": "logical",
            "rules": subObjects,
        ]
        switch rule.type {
        case .or:
            object["mode"] = "or"
        case .not:
            // NOT == AND over the operands, inverted.
            object["mode"] = "and"
            object["invert"] = true
        default: // .and
            object["mode"] = "and"
        }
        return object
    }

    // MARK: - rule_set

    private func ruleSetObject(for entry: RuleSetEntry) -> [String: Any] {
        var object: [String: Any] = [
            "type": entry.source.rawValue,
            "tag": entry.tag,
            "format": entry.format.rawValue,
        ]
        switch entry.source {
        case .remote:
            if let url = entry.url, !url.isEmpty {
                object["url"] = url
            }
            if let detour = entry.downloadDetour, !detour.isEmpty {
                object["download_detour"] = detour
            }
            if let interval = entry.updateInterval, !interval.isEmpty {
                object["update_interval"] = interval
            }
        case .local:
            if let path = entry.path, !path.isEmpty {
                object["path"] = path
            }
        }
        return object
    }

    // MARK: - Helpers

    /// Splits a comma-separated literal into trimmed, non-empty entries.
    private func splitValues(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
