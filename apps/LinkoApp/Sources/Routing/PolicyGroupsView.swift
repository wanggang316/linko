import LinkoKit
import SwiftUI

/// Native grouped editor for **policy groups** — the layer above individual
/// nodes that lets the user build manual selectors and auto latency-test groups
/// (and degraded fallback / load-balance variants), each aggregating nodes and
/// other groups. Groups compile to sing-box `selector` / `urltest` outbounds;
/// rules and `route.final` target group tags.
///
/// Persists by writing the mutated `RoutingConfig` back through
/// `AppState.updatePreferences`, the established preference-commit path.
struct PolicyGroupsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selection: PolicyGroup.ID?
    @State private var editingGroup: PolicyGroup?
    @State private var isCreating = false

    private var groups: [PolicyGroup] { appState.preferences.routing.groups }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 640, height: 560)
        .sheet(item: $editingGroup) { group in
            PolicyGroupEditorSheet(
                group: group,
                isNew: isCreating,
                existingNames: groups.map(\.name),
                nodeTags: nodeTags,
                groupTags: groups.map(\.name)
            ) { saved in
                commit(saved, isNew: isCreating)
            }
            .environmentObject(appState)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            SectionHeader("策略组", symbolName: "rectangle.3.group") {
                CountBadge(count: groups.count)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Button {
                beginCreate()
            } label: {
                Label("新建策略组", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if groups.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                ForEach(groups) { group in
                    PolicyGroupRow(group: group, nodeTags: nodeTags)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { beginEdit(group) }
                        .contextMenu { rowMenu(for: group) }
                        .tag(group.id)
                }
                .onMove(perform: moveGroups)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .safeAreaInset(edge: .bottom) { listToolbar }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Color.tertiaryLabel)
            Text("还没有策略组")
                .font(Theme.Font.heading)
                .foregroundStyle(Theme.Color.label)
            Text("策略组让你把多个节点聚合为「手动选择」或「自动测速」的出站，供路由规则和默认出站引用。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                beginCreate()
            } label: {
                Label("新建策略组", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
    }

    private var listToolbar: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button {
                if let group = selectedGroup { beginEdit(group) }
            } label: {
                Image(systemName: "pencil")
            }
            .disabled(selectedGroup == nil)
            .help("编辑所选策略组")

            Button {
                if let group = selectedGroup { delete(group) }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(selectedGroup == nil || selectedGroup?.isDefault == true)
            .help("删除所选策略组")

            Spacer()
            Text("默认出站标记为「默认」，不可删除。")
                .font(Theme.Font.caption2)
                .foregroundStyle(Theme.Color.tertiaryLabel)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(.bar)
    }

    @ViewBuilder
    private func rowMenu(for group: PolicyGroup) -> some View {
        Button("编辑") { beginEdit(group) }
        if !group.isDefault {
            Button("删除", role: .destructive) { delete(group) }
        }
    }

    private var selectedGroup: PolicyGroup? {
        groups.first { $0.id == selection }
    }

    // MARK: - Derived

    /// Node "tags" for the member picker. Display names map to outbound tags
    /// one-to-one for the common case of unique node names; duplicates are
    /// surfaced as warnings by the engine's `validate`.
    private var nodeTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for node in appState.allNodes where !seen.contains(node.name) {
            seen.insert(node.name)
            result.append(node.name)
        }
        return result
    }

    // MARK: - Mutations

    private func beginCreate() {
        let base = "策略组"
        var name = base
        var index = 1
        let taken = Set(groups.map(\.name))
        while taken.contains(name) {
            index += 1
            name = "\(base) \(index)"
        }
        isCreating = true
        editingGroup = PolicyGroup(name: name, type: .select)
    }

    private func beginEdit(_ group: PolicyGroup) {
        isCreating = false
        editingGroup = group
    }

    private func commit(_ group: PolicyGroup, isNew: Bool) {
        var preferences = appState.preferences
        if let index = preferences.routing.groups.firstIndex(where: { $0.id == group.id }) {
            preferences.routing.groups[index] = group
        } else {
            preferences.routing.groups.append(group)
        }
        selection = group.id
        persist(preferences)
    }

    private func delete(_ group: PolicyGroup) {
        guard !group.isDefault else { return }
        var preferences = appState.preferences
        preferences.routing.groups.removeAll { $0.id == group.id }
        // Drop dangling member references to the deleted group.
        for index in preferences.routing.groups.indices {
            preferences.routing.groups[index].members.removeAll {
                $0.kind == .group && $0.tag == group.name
            }
        }
        if selection == group.id { selection = nil }
        persist(preferences)
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        var preferences = appState.preferences
        preferences.routing.groups.move(fromOffsets: source, toOffset: destination)
        persist(preferences)
    }

    private func persist(_ preferences: AppPreferences) {
        Task { await appState.updatePreferences(preferences) }
    }
}

// =============================================================================
// MARK: - Row
// =============================================================================

/// A single policy-group list row: name, behavior badge, and a member summary.
private struct PolicyGroupRow: View {
    let group: PolicyGroup
    let nodeTags: [String]

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: group.type.symbolName)
                .font(.body)
                .foregroundStyle(Theme.Color.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(group.name)
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(Theme.Color.label)
                    if group.isDefault {
                        Text("默认")
                            .font(Theme.Font.caption2.weight(.semibold))
                            .foregroundStyle(Theme.Color.accent)
                            .padding(.horizontal, Theme.Spacing.xs)
                            .padding(.vertical, 1)
                            .background(Theme.Color.accent.opacity(0.14), in: Capsule())
                    }
                }
                Text(memberSummary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Text(group.type.displayName)
                .font(Theme.Font.caption2.weight(.medium))
                .foregroundStyle(Theme.Color.secondaryLabel)
                .padding(.horizontal, Theme.Spacing.xs + 2)
                .padding(.vertical, 2)
                .background(Theme.Color.hover, in: Capsule())
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private var memberSummary: String {
        guard !group.members.isEmpty else { return "无成员" }
        let names = group.members.prefix(4).map(\.tag)
        let suffix = group.members.count > 4 ? " 等 \(group.members.count) 项" : ""
        return names.joined(separator: "、") + suffix
    }
}

// =============================================================================
// MARK: - Editor sheet
// =============================================================================

/// Modal editor for one policy group: name, behavior, ordered members chosen
/// from nodes / other groups / built-ins, and url-test tuning when relevant.
private struct PolicyGroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PolicyGroup
    let isNew: Bool
    let existingNames: [String]
    let nodeTags: [String]
    let groupTags: [String]
    let onSave: (PolicyGroup) -> Void

    @State private var intervalText = ""
    @State private var toleranceText = ""

    init(
        group: PolicyGroup,
        isNew: Bool,
        existingNames: [String],
        nodeTags: [String],
        groupTags: [String],
        onSave: @escaping (PolicyGroup) -> Void
    ) {
        _draft = State(initialValue: group)
        self.isNew = isNew
        self.existingNames = existingNames
        self.nodeTags = nodeTags
        self.groupTags = groupTags
        self.onSave = onSave
        _intervalText = State(initialValue: group.interval ?? "")
        _toleranceText = State(initialValue: group.tolerance.map(String.init) ?? "")
    }

    // Names of other groups (excluding self) eligible for nesting.
    private var nestableGroupTags: [String] {
        groupTags.filter { $0 != draft.name }
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameConflict: Bool {
        existingNames.contains { $0 != originalName && $0 == trimmedName }
    }

    @State private var originalName: String = ""

    private var canSave: Bool {
        !trimmedName.isEmpty && !nameConflict && trimmedName != "direct"
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            Form {
                identitySection
                if draft.type.usesURLTestParameters {
                    urlTestSection
                }
                membersSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .onAppear { originalName = draft.isDefault ? draft.name : (isNew ? "" : draft.name) }
    }

    private var sheetHeader: some View {
        HStack {
            Text(isNew ? "新建策略组" : "编辑策略组")
                .font(Theme.Font.sectionTitle)
            Spacer()
            Image(systemName: draft.type.symbolName)
                .font(.title2)
                .foregroundStyle(Theme.Color.accent)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: Identity

    private var identitySection: some View {
        Section {
            LabeledContent("名称") {
                TextField("策略组名称", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                    .disabled(draft.isDefault)
            }
            if draft.isDefault {
                Label("默认出站组名称固定为 “proxy”，不可修改。", systemImage: "lock")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            } else if nameConflict {
                Label("已存在同名策略组。", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
            } else if trimmedName == "direct" {
                Label("名称不能为保留字 “direct”。", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
            }

            Picker("行为", selection: $draft.type) {
                ForEach(GroupType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)

            Label {
                Text(draft.type.explanation)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(Theme.Color.info)
            }
        } header: {
            Text("基本")
        }
    }

    // MARK: url-test

    private var urlTestSection: some View {
        Section {
            LabeledContent("测试地址") {
                TextField(AppPreferences.default.delayTestURL, text: testURLBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.monoSmall)
                    .frame(minWidth: 240)
            }
            LabeledContent("测试间隔") {
                TextField("3m", text: $intervalText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onChange(of: intervalText) { _, value in
                        let trimmed = value.trimmingCharacters(in: .whitespaces)
                        draft.interval = trimmed.isEmpty ? nil : trimmed
                    }
            }
            LabeledContent("容差 (ms)") {
                TextField("50", text: $toleranceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onChange(of: toleranceText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { toleranceText = digits }
                        draft.tolerance = digits.isEmpty ? nil : Int(digits)
                    }
            }
        } header: {
            Text("自动测速")
        } footer: {
            if draft.type == .fallback || draft.type == .loadBalance {
                Text("sing-box 没有独立的\(draft.type == .fallback ? "故障转移" : "负载均衡")出站类型，linko 以「自动测速」近似实现：始终选用延迟最低且可用的成员。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            } else {
                Text("留空则使用核心默认值。间隔示例：30s、3m、1h。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        }
    }

    private var testURLBinding: Binding<String> {
        Binding(
            get: { draft.testURL ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                draft.testURL = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    // MARK: Members

    private var membersSection: some View {
        Section {
            if draft.members.isEmpty {
                Text("尚未选择成员。下方可勾选节点、内置出站或其它策略组。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            } else {
                ForEach(draft.members) { member in
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: member.kind.symbolName)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                            .frame(width: 18)
                        Text(member.tag)
                            .font(Theme.Font.body)
                        Spacer()
                        Text(member.kind.displayName)
                            .font(Theme.Font.caption2)
                            .foregroundStyle(Theme.Color.tertiaryLabel)
                    }
                }
                .onMove { source, destination in
                    draft.members.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    draft.members.remove(atOffsets: offsets)
                }
            }

            DisclosureGroup("添加成员") {
                memberPicker(title: "内置出站", symbol: "circle.dashed", tags: builtinTags, kind: .builtin)
                memberPicker(title: "节点", symbol: "point.3.connected.trianglepath.dotted", tags: nodeTags, kind: .node)
                memberPicker(title: "其它策略组", symbol: "rectangle.3.group", tags: nestableGroupTags, kind: .group)
            }
        } header: {
            Text("成员（按顺序，可拖动排序）")
        } footer: {
            Text("手动选择组按列表顺序展示；自动测速组从中挑选延迟最低者。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    private let builtinTags = ["direct", "proxy"]

    @ViewBuilder
    private func memberPicker(title: String, symbol: String, tags: [String], kind: PolicyGroupMember.Kind) -> some View {
        if tags.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Label(title, systemImage: symbol)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.Color.secondaryLabel)
                ForEach(tags, id: \.self) { tag in
                    Toggle(isOn: memberBinding(kind: kind, tag: tag)) {
                        Text(tag)
                            .font(Theme.Font.body)
                            .lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
        }
    }

    private func memberBinding(kind: PolicyGroupMember.Kind, tag: String) -> Binding<Bool> {
        Binding(
            get: { draft.members.contains { $0.kind == kind && $0.tag == tag } },
            set: { isOn in
                if isOn {
                    guard !draft.members.contains(where: { $0.kind == kind && $0.tag == tag }) else { return }
                    draft.members.append(PolicyGroupMember(kind: kind, tag: tag))
                } else {
                    draft.members.removeAll { $0.kind == kind && $0.tag == tag }
                }
            }
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("保存") {
                draft.name = trimmedName
                onSave(draft)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }
}

// =============================================================================
// MARK: - Display helpers
// =============================================================================

private extension GroupType {
    var displayName: String {
        switch self {
        case .select: return "手动选择"
        case .urlTest: return "自动测速"
        case .fallback: return "故障转移"
        case .loadBalance: return "负载均衡"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "hand.tap"
        case .urlTest: return "bolt.horizontal"
        case .fallback: return "arrow.triangle.2.circlepath"
        case .loadBalance: return "scale.3d"
        }
    }

    var explanation: String {
        switch self {
        case .select:
            return "由你手动从成员中选用一个出站（sing-box selector）。"
        case .urlTest:
            return "自动选用延迟最低且可用的成员（sing-box urltest）。"
        case .fallback:
            return "近似故障转移：始终选用可用且延迟最低的成员（以 urltest 实现）。"
        case .loadBalance:
            return "sing-box 暂无原生负载均衡，linko 以 urltest 近似（不做真正的分流）。"
        }
    }
}

private extension PolicyGroupMember.Kind {
    var displayName: String {
        switch self {
        case .node: return "节点"
        case .group: return "策略组"
        case .builtin: return "内置"
        }
    }

    var symbolName: String {
        switch self {
        case .node: return "point.3.connected.trianglepath.dotted"
        case .group: return "rectangle.3.group"
        case .builtin: return "circle.dashed"
        }
    }
}
