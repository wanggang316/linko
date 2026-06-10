import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - RuleEditorView
// =============================================================================

/// A modal sheet for creating or editing a single `RoutingRule`. Drives a
/// grouped `Form`: choose the rule type, supply the matcher value (a free-text
/// field, a rule-set picker, or a nested sub-rule editor for logical kinds),
/// then pick the outbound target. Commits an updated rule on "保存".
struct RuleEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// Working copy of the rule, mutated locally until the user saves.
    @State private var draft: RoutingRule
    let isNew: Bool
    let targets: RoutingTargets
    let ruleSets: [RuleSetEntry]
    let onSave: (RoutingRule) -> Void

    init(
        rule: RoutingRule,
        isNew: Bool,
        targets: RoutingTargets,
        ruleSets: [RuleSetEntry],
        onSave: @escaping (RoutingRule) -> Void
    ) {
        _draft = State(initialValue: rule)
        self.isNew = isNew
        self.targets = targets
        self.ruleSets = ruleSets
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                typeSection
                valueSection
                targetSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 520, height: 540)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: draft.type.symbolName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.Color.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(isNew ? "新建规则" : "编辑规则")
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.Color.label)
                Text(draft.type.displayName)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
            Spacer()
            Toggle("启用", isOn: $draft.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Type

    private var typeSection: some View {
        Section("类型") {
            Picker("匹配类型", selection: $draft.type) {
                ForEach(RuleTypeCategory.allCases, id: \.self) { category in
                    Section(category.title) {
                        ForEach(category.types, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }
            }
            .onChange(of: draft.type) { _, newType in
                normalize(for: newType)
            }
        }
    }

    // MARK: - Value / sub-rules / rule-set

    @ViewBuilder
    private var valueSection: some View {
        if draft.type.isLogical {
            LogicalSubRulesEditor(subRules: $draft.subRules, ruleSets: ruleSets)
        } else if draft.type.usesRuleSet {
            ruleSetSection
        } else if draft.type.isFinal {
            Section {
                Label("兜底规则匹配所有未命中其它规则的流量，无需匹配值。",
                      systemImage: "flag.checkered")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        } else {
            Section {
                TextField(
                    "匹配值",
                    text: $draft.value,
                    prompt: Text(draft.type.valuePlaceholder)
                )
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.mono)
            } header: {
                Text("匹配值")
            } footer: {
                Text(valueHint)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        }
    }

    @ViewBuilder
    private var ruleSetSection: some View {
        Section {
            if ruleSets.isEmpty {
                Label("尚未定义规则集。请先在「规则集」中添加，或直接填写标签。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
                TextField("规则集标签", text: $draft.value, prompt: Text(draft.type.valuePlaceholder))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
            } else {
                Picker("规则集", selection: $draft.value) {
                    Text("（请选择）").tag("")
                    ForEach(ruleSets) { entry in
                        Text(entry.tag).tag(entry.tag)
                    }
                }
            }
        } header: {
            Text(draft.type == .geoip ? "GeoIP / 规则集" : "规则集")
        } footer: {
            Text("引用 route.rule_set 中的规则集标签。GeoIP/GeoSite 通过远程规则集匹配。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    private var valueHint: String {
        switch draft.type {
        case .domainSuffix: return "匹配该后缀及其所有子域名，例如 google.com 命中 www.google.com。"
        case .domainKeyword: return "域名中包含该关键词即命中。"
        case .domainRegex: return "使用正则表达式匹配完整域名。"
        case .ipCIDR, .ipCIDR6: return "CIDR 形式的 IP 段，例如 10.0.0.0/8。"
        case .srcIPCIDR: return "按来源 IP 段匹配（本机发起方）。"
        case .port, .destPort: return "单个端口或范围（start:end），可用逗号分隔多个。"
        case .srcPort: return "按来源端口匹配。"
        case .network: return "取值 tcp 或 udp。"
        case .protocolSniff: return "按嗅探到的应用层协议匹配，如 tls、http、quic。"
        case .processName: return "发起连接的进程名（不含路径）。"
        case .processPath: return "发起连接进程的完整可执行文件路径。"
        default: return "用于匹配的字面值。"
        }
    }

    // MARK: - Target

    private var targetSection: some View {
        Section {
            Menu {
                TargetMenuItems(
                    targets: targets,
                    selectedTag: draft.target,
                    onSelect: { draft.target = $0 }
                )
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: targets.resolve(draft.target).symbolName)
                        .foregroundStyle(Theme.Color.accent)
                    Text(targets.resolve(draft.target).displayName)
                        .foregroundStyle(Theme.Color.label)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Theme.Color.tertiaryLabel)
                }
            }
            .menuStyle(.borderlessButton)

            if !targets.isResolved(draft.target) {
                Label("当前目标「\(draft.target)」不在已知节点/策略组中，配置生成时将被丢弃。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
            }
        } header: {
            Text("出站目标")
        } footer: {
            Text("命中此规则的流量将转发到所选节点或策略组。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let problem = validationProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
                    .lineLimit(1)
            }
            Spacer()
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(validationProblem != nil)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Validation

    /// A short Chinese description of the first blocking problem, or `nil` when
    /// the rule is savable.
    private var validationProblem: String? {
        if draft.target.trimmingCharacters(in: .whitespaces).isEmpty {
            return "请选择出站目标"
        }
        if draft.type.isLogical {
            return draft.subRules.isEmpty ? "逻辑规则至少需要一个子条件" : nil
        }
        if draft.type.isFinal {
            return nil
        }
        if draft.value.trimmingCharacters(in: .whitespaces).isEmpty {
            return draft.type.usesRuleSet ? "请选择规则集" : "请输入匹配值"
        }
        return nil
    }

    // MARK: - Actions

    /// Resets fields that don't apply to a newly chosen type so a switch from,
    /// say, a leaf matcher to a logical one (or vice versa) leaves no stale data.
    private func normalize(for newType: RuleType) {
        if newType.isLogical {
            draft.value = ""
        } else {
            draft.subRules = []
            if newType.isFinal { draft.value = "" }
        }
    }

    private func save() {
        guard validationProblem == nil else { return }
        var result = draft
        result.value = result.value.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(result)
        dismiss()
    }
}

// =============================================================================
// MARK: - LogicalSubRulesEditor
// =============================================================================

/// Inline editor for the operands of a logical (AND/OR/NOT) rule. Each operand
/// is a leaf matcher with a type and a value; the outbound target is inherited
/// from the parent logical rule, so sub-rules carry no target of their own.
private struct LogicalSubRulesEditor: View {
    @Binding var subRules: [RoutingRule]
    let ruleSets: [RuleSetEntry]

    var body: some View {
        Section {
            if subRules.isEmpty {
                Text("尚无子条件。点按下方「添加子条件」开始。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            } else {
                ForEach($subRules) { $sub in
                    SubRuleRow(sub: $sub, ruleSets: ruleSets) {
                        subRules.removeAll { $0.id == sub.id }
                    }
                }
                .onDelete { subRules.remove(atOffsets: $0) }
            }
            Button {
                subRules.append(RoutingRule(type: .domainSuffix, value: "", target: ""))
            } label: {
                Label("添加子条件", systemImage: "plus.circle")
            }
        } header: {
            Text("子条件")
        } footer: {
            Text("所有子条件按所选逻辑（与 / 或 / 非）组合后整体命中，再走父规则的出站目标。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }
}

/// A single operand row inside a logical rule: a compact type picker, a value
/// field (or rule-set picker), and a delete button.
private struct SubRuleRow: View {
    @Binding var sub: RoutingRule
    let ruleSets: [RuleSetEntry]
    let onDelete: () -> Void

    /// Leaf matcher types valid inside a logical rule (no nested logicals, no
    /// final). Keeps the picker focused and prevents illegal nesting.
    private static let leafTypes: [RuleType] = RuleType.allCases.filter {
        !$0.isLogical && !$0.isFinal
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Picker("", selection: $sub.type) {
                ForEach(Self.leafTypes, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            if sub.type.usesRuleSet, !ruleSets.isEmpty {
                Picker("", selection: $sub.value) {
                    Text("（规则集）").tag("")
                    ForEach(ruleSets) { Text($0.tag).tag($0.tag) }
                }
                .labelsHidden()
            } else {
                TextField("", text: $sub.value, prompt: Text(sub.type.valuePlaceholder))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.monoSmall)
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Color.tertiaryLabel)
        }
    }
}
