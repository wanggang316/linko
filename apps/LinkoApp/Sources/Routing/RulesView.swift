import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - RulesView
// =============================================================================

/// The routing-rules surface: a native, reorderable list of `RoutingRule`s with
/// add / edit / delete / drag-to-reorder, plus a "导入规则…" entry that migrates
/// Surge `[Rule]` sections and Clash `rules:` lists. Rules are evaluated top to
/// bottom (first match wins); the order shown here is the order emitted to
/// sing-box `route.rules`, so reordering is meaningful, not cosmetic.
///
/// This is a self-contained, window-ready root. It owns only its own state and
/// commits every mutation through `AppState.updatePreferences`. It can be hosted
/// as a Dashboard sidebar item (embed `RulesView()` in the detail pane) or in a
/// dedicated `Window("规则", id: ...) { RulesView().environmentObject(appState) }`.
struct RulesView: View {
    @EnvironmentObject private var appState: AppState

    /// The rule currently being edited in the sheet, or `nil`.
    @State private var editingRule: EditingRule?
    /// Whether the import sheet is presented.
    @State private var isImporting = false
    /// Transient banner describing the most recent import outcome.
    @State private var importSummary: ImportSummary?

    var body: some View {
        Group {
            if rules.isEmpty {
                emptyState
            } else {
                ruleList
            }
        }
        .navigationTitle("规则")
        .toolbar { toolbarContent }
        .sheet(item: $editingRule) { editing in
            RuleEditorView(
                rule: editing.rule,
                isNew: editing.isNew,
                targets: targets,
                ruleSets: routing.ruleSets
            ) { result in
                apply(editing: editing, result: result)
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $isImporting) {
            ImportRulesView(
                existingPolicyTags: Set(targets.all.map(\.tag))
            ) { imported, summary in
                merge(importedRules: imported, summary: summary)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: - Derived state

    private var routing: RoutingConfig { appState.preferences.routing }
    private var rules: [RoutingRule] { routing.rules }

    /// The catalogue of outbound targets a rule can point at, rebuilt from the
    /// live config and node list on every render so newly imported subscriptions
    /// or groups appear immediately. Node outbound tags are computed with the
    /// same deterministic dedup logic the config builder and Clash API path use,
    /// via a stateless `SingBoxConfigBuilder` instance.
    private var targets: RoutingTargets {
        let nodes = appState.allNodes
        let tags = Self.tagBuilder.outboundTags(for: nodes)
        return RoutingTargets(routing: routing, nodes: nodes, nodeTags: tags)
    }

    /// A stateless tag resolver shared across renders; `outboundTags(for:)` is a
    /// pure function of its input, so a single instance is safe and cheap.
    private static let tagBuilder = SingBoxConfigBuilder()

    // MARK: - Rule list

    private var ruleList: some View {
        VStack(spacing: 0) {
            if let summary = importSummary {
                ImportBanner(summary: summary) { importSummary = nil }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.sm)
            }
            List {
                Section {
                    ForEach(rules) { rule in
                        RuleRow(rule: rule, targets: targets)
                            .contentShape(Rectangle())
                            .onTapGesture { beginEditing(rule) }
                            .contextMenu { rowMenu(for: rule) }
                            .listRowInsets(EdgeInsets(
                                top: Theme.Spacing.xs, leading: Theme.Spacing.sm,
                                bottom: Theme.Spacing.xs, trailing: Theme.Spacing.sm
                            ))
                    }
                    .onMove(perform: move)
                    .onDelete(perform: delete)
                } header: {
                    listHeader
                } footer: {
                    Text("规则按从上到下的顺序匹配，命中即停止。拖动可调整优先级。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                }
            }
            .listStyle(.inset)
            .animation(.easeInOut(duration: 0.15), value: rules)
        }
    }

    private var listHeader: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("路由规则")
            Spacer(minLength: Theme.Spacing.xs)
            Text("兜底 → ")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
            FinalTargetMenu(
                currentTag: routing.finalTarget,
                targets: targets,
                onSelect: setFinalTarget
            )
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Theme.Color.accent.opacity(0.7))
            VStack(spacing: Theme.Spacing.xxs) {
                Text("尚未配置路由规则")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.label)
                Text("添加规则可按域名、IP、地区、进程等条件分流到不同的策略组或节点。\n未命中任何规则的流量将走兜底出站（\(routing.finalTarget)）。")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Spacing.sm) {
                Button(action: addRule) {
                    Label("新建规则", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button(action: { isImporting = true }) {
                    Label("导入规则…", systemImage: "square.and.arrow.down")
                }
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { isImporting = true }) {
                Label("导入规则", systemImage: "square.and.arrow.down")
            }
            .help("从 Surge 或 Clash 配置导入规则")
            Button(action: addRule) {
                Label("新建规则", systemImage: "plus")
            }
            .help("添加一条路由规则")
        }
    }

    @ViewBuilder
    private func rowMenu(for rule: RoutingRule) -> some View {
        Button { beginEditing(rule) } label: { Label("编辑…", systemImage: "pencil") }
        Button {
            setEnabled(rule, enabled: !rule.isEnabled)
        } label: {
            Label(rule.isEnabled ? "停用" : "启用",
                  systemImage: rule.isEnabled ? "pause.circle" : "play.circle")
        }
        Button { duplicate(rule) } label: { Label("复制", systemImage: "plus.square.on.square") }
        Divider()
        Button(role: .destructive) {
            removeRule(rule)
        } label: { Label("删除", systemImage: "trash") }
    }

    // MARK: - Editing

    /// A rule being edited, distinguishing a brand-new draft from an existing
    /// rule so the editor can title and commit appropriately.
    private struct EditingRule: Identifiable {
        let rule: RoutingRule
        let isNew: Bool
        var id: UUID { rule.id }
    }

    private func addRule() {
        let draft = RoutingRule(
            type: .domainSuffix,
            value: "",
            target: targets.defaultTag
        )
        editingRule = EditingRule(rule: draft, isNew: true)
    }

    private func beginEditing(_ rule: RoutingRule) {
        editingRule = EditingRule(rule: rule, isNew: false)
    }

    private func apply(editing: EditingRule, result: RoutingRule) {
        var next = routing
        if editing.isNew {
            next.rules.append(result)
        } else if let index = next.rules.firstIndex(where: { $0.id == result.id }) {
            next.rules[index] = result
        }
        commit(next)
    }

    private func duplicate(_ rule: RoutingRule) {
        var copy = rule
        copy.id = UUID()
        var next = routing
        if let index = next.rules.firstIndex(where: { $0.id == rule.id }) {
            next.rules.insert(copy, at: next.rules.index(after: index))
        } else {
            next.rules.append(copy)
        }
        commit(next)
    }

    // MARK: - Mutations

    private func move(from source: IndexSet, to destination: Int) {
        var next = routing
        next.rules.move(fromOffsets: source, toOffset: destination)
        commit(next)
    }

    private func delete(at offsets: IndexSet) {
        var next = routing
        next.rules.remove(atOffsets: offsets)
        commit(next)
    }

    private func removeRule(_ rule: RoutingRule) {
        var next = routing
        next.rules.removeAll { $0.id == rule.id }
        commit(next)
    }

    private func setEnabled(_ rule: RoutingRule, enabled: Bool) {
        var next = routing
        guard let index = next.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        next.rules[index].isEnabled = enabled
        commit(next)
    }

    private func setFinalTarget(_ tag: String) {
        var next = routing
        next.finalTarget = tag
        commit(next)
    }

    private func merge(importedRules: [RoutingRule], summary: ImportSummary) {
        var next = routing
        next.rules.append(contentsOf: importedRules)
        commit(next)
        importSummary = summary
    }

    /// Persists a mutated routing config through the standard preferences path,
    /// which restarts the core when it is running so the new routing takes
    /// effect immediately.
    private func commit(_ newRouting: RoutingConfig) {
        var preferences = appState.preferences
        guard preferences.routing != newRouting else { return }
        preferences.routing = newRouting
        Task { await appState.updatePreferences(preferences) }
    }
}

// =============================================================================
// MARK: - RuleRow
// =============================================================================

/// One row in the rule list: a type chip, the matcher value (monospace), and a
/// trailing "→ target" pill. Disabled rules dim; unresolved targets and missing
/// values flag with a warning glyph.
private struct RuleRow: View {
    let rule: RoutingRule
    let targets: RoutingTargets

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: rule.type.symbolName)
                .font(.body)
                .foregroundStyle(rule.isEnabled ? Theme.Color.accent : Theme.Color.tertiaryLabel)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(rule.type.displayName)
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(rule.isEnabled ? Theme.Color.label : Theme.Color.secondaryLabel)
                    TokenBadge(text: rule.type.token)
                    if !rule.isEnabled {
                        Text("已停用")
                            .font(Theme.Font.caption2.weight(.medium))
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                }
                valueLine
            }

            Spacer(minLength: Theme.Spacing.sm)

            targetPill
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .opacity(rule.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    private var valueLine: some View {
        if rule.type.isLogical {
            Text(logicalSummary)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if rule.type.isFinal {
            Text("未命中其它规则的所有流量")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        } else if rule.value.isEmpty {
            Label("缺少匹配值", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.warning)
        } else {
            Text(rule.value)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// A compact "AND(3)" / "OR(2)" style preview of a logical rule's operands.
    private var logicalSummary: String {
        let count = rule.subRules.count
        let head = rule.subRules.prefix(2).map { "\($0.type.token) \($0.value)" }.joined(separator: ", ")
        let suffix = count > 2 ? ", …(\(count))" : ""
        return head.isEmpty ? "无子条件" : head + suffix
    }

    private var targetPill: some View {
        let target = targets.resolve(rule.target)
        let resolved = targets.isResolved(rule.target)
        return HStack(spacing: Theme.Spacing.xxs + 1) {
            Image(systemName: resolved ? target.symbolName : "questionmark.circle")
                .font(.caption2.weight(.semibold))
            Text(target.displayName)
                .font(Theme.Font.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(resolved ? Theme.Color.accent : Theme.Color.warning)
        .padding(.horizontal, Theme.Spacing.xs + 1)
        .padding(.vertical, Theme.Spacing.xxs)
        .background((resolved ? Theme.Color.accent : Theme.Color.warning).opacity(0.12), in: Capsule())
        .help(resolved ? "出站目标：\(target.tag)" : "未知出站目标「\(rule.target)」——请在编辑中重新指定")
    }
}

// =============================================================================
// MARK: - Shared chips
// =============================================================================

/// A small monospace token badge, e.g. `DOMAIN-SUFFIX`, so power users see the
/// underlying Surge/Clash keyword at a glance.
struct TokenBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.caption2.monospaced())
            .foregroundStyle(Theme.Color.secondaryLabel)
            .padding(.horizontal, Theme.Spacing.xxs + 1)
            .padding(.vertical, 1)
            .background(Theme.Color.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}

// =============================================================================
// MARK: - FinalTargetMenu
// =============================================================================

/// The `route.final` outbound picker shown in the list header, so the user can
/// retarget unmatched traffic without leaving the rule list.
private struct FinalTargetMenu: View {
    let currentTag: String
    let targets: RoutingTargets
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            TargetMenuItems(targets: targets, selectedTag: currentTag, onSelect: onSelect)
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: "flag.checkered")
                Text(targets.resolve(currentTag).displayName)
                    .lineLimit(1)
            }
            .font(Theme.Font.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// =============================================================================
// MARK: - TargetMenuItems
// =============================================================================

/// Shared, grouped menu content for choosing an outbound target (built-ins,
/// groups, nodes). Reused by the final-target menu and the rule editor.
struct TargetMenuItems: View {
    let targets: RoutingTargets
    let selectedTag: String
    let onSelect: (String) -> Void

    var body: some View {
        section("内置", items: targets.builtins)
        if !targets.groups.isEmpty {
            Divider()
            section("策略组", items: targets.groups)
        }
        if !targets.nodes.isEmpty {
            Divider()
            section("节点", items: targets.nodes)
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [RoutingTarget]) -> some View {
        Section(title) {
            ForEach(items) { target in
                Button {
                    onSelect(target.tag)
                } label: {
                    if target.tag == selectedTag {
                        Label(target.displayName, systemImage: "checkmark")
                    } else {
                        Text(target.displayName)
                    }
                }
            }
        }
    }
}

// =============================================================================
// MARK: - ImportBanner
// =============================================================================

/// A dismissible banner summarizing the last import: counts plus a disclosure
/// of warnings for skipped/unmapped lines.
private struct ImportBanner: View {
    let summary: ImportSummary
    let onDismiss: () -> Void

    @State private var showWarnings = false

    var body: some View {
        Card(material: .thinMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .foregroundStyle(Theme.Color.accent)
                    Text(summary.headline)
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(Theme.Color.label)
                    Spacer(minLength: Theme.Spacing.xs)
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
                }
                if !summary.warnings.isEmpty {
                    DisclosureGroup(isExpanded: $showWarnings) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(summary.warnings.enumerated()), id: \.offset) { _, warning in
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.Color.warning)
                                    Text(warning)
                                        .font(Theme.Font.monoSmall)
                                        .foregroundStyle(Theme.Color.secondaryLabel)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(.top, Theme.Spacing.xxs)
                    } label: {
                        Text("\(summary.warnings.count) 条提示")
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(Theme.Color.warning)
                    }
                }
            }
        }
    }
}

/// Outcome of a rule import, surfaced in the banner after merging.
struct ImportSummary: Equatable {
    let importedCount: Int
    let unresolvedPolicies: [String]
    let warnings: [String]

    var headline: String {
        var parts = ["已导入 \(importedCount) 条规则"]
        if !unresolvedPolicies.isEmpty {
            parts.append("\(unresolvedPolicies.count) 个策略名未匹配")
        }
        return parts.joined(separator: "，")
    }
}
