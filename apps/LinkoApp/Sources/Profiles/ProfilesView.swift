import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - ProfilesView
// =============================================================================

/// The 配置 (Profiles) management surface: a native list of every stored profile
/// — the active one pinned at the top with a distinct treatment, the rest below
/// — with create / 复制 / 重命名 / 删除 / 切换 actions and an at-a-glance summary
/// (mode badge, subscription + node counts, last-updated time) per profile.
///
/// A profile is a named bundle of `{subscriptions, routing config, selected node,
/// proxy mode, ports}`. Switching the active profile re-generates + validates +
/// restarts the running core, so the heavy work lives entirely in `AppState`
/// (`ProfileManaging`); this view only binds to the cheap value-type
/// `[ProfileSummary]` projection and drives the six management methods.
///
/// This is a self-contained, window-ready root. It owns only its own transient
/// UI state and commits every mutation through `AppState`'s `ProfileManaging`
/// surface (`createProfile(named:)` / `duplicateProfile(id:)` /
/// `renameProfile(id:to:)` / `deleteProfile(id:)` / `switchProfile(id:)`).
///
/// Build-agent wiring note: to surface this as a Dashboard sidebar entry, add a
/// `case profiles` to `DashboardSection` (title "配置", a routing-style section so
/// it owns its own navigation title + toolbar — include it in `selfChromedSections`
/// so `isRoutingSection` is `true`), list it in a new "配置" sidebar `Section`, and
/// return `ProfilesView()` from `DashboardView.detail`. The view already declares
/// `.navigationTitle("配置")` and its own toolbar, matching the routing panes.
struct ProfilesView: View {
    @EnvironmentObject private var appState: AppState

    /// `true` while the "new profile" sheet is presented.
    @State private var isCreating = false
    /// The profile being renamed in the inline rename sheet, or `nil`.
    @State private var renaming: RenameTarget?
    /// The profile pending delete confirmation, or `nil`.
    @State private var pendingDelete: ProfileSummary?
    /// Ids with a switch/duplicate/delete operation in flight, so rows can show a
    /// spinner and re-entrancy is blocked without freezing the whole window.
    @State private var busyIDs: Set<UUID> = []
    /// `true` while a create/duplicate that ends in an activation is running.
    @State private var isMutating = false
    /// Re-evaluated once a minute so the relative "更新于" times stay fresh.
    @State private var now = Date()

    private let clockTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        content
            .navigationTitle("配置")
            .toolbar { toolbarContent }
            .sheet(isPresented: $isCreating) {
                ProfileNameSheet(
                    title: "新建配置",
                    subtitle: "为新的配置档案起一个名称",
                    confirmTitle: "创建",
                    initialName: ""
                ) { name in
                    create(named: name)
                }
            }
            .sheet(item: $renaming) { target in
                ProfileNameSheet(
                    title: "重命名配置",
                    subtitle: "设置一个便于识别的名称",
                    confirmTitle: "保存",
                    initialName: target.name
                ) { newName in
                    appState.renameProfile(id: target.id, to: newName)
                }
            }
            .confirmationDialog(
                "删除配置「\(pendingDelete?.name ?? "")」？",
                isPresented: deleteDialogBinding,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let target = pendingDelete { delete(target) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将移除该配置及其全部订阅与路由设置。若删除的是当前配置，会自动切换到相邻配置并重启代理。")
            }
            .onReceive(clockTimer) { now = $0 }
            .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: - Derived state

    private var summaries: [ProfileSummary] { appState.profileSummaries }

    private var activeSummary: ProfileSummary? {
        summaries.first { $0.id == appState.activeProfileID }
    }

    private var otherSummaries: [ProfileSummary] {
        summaries.filter { $0.id != appState.activeProfileID }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    /// The active profile is the only one whose delete is blocked when it is the
    /// sole remaining profile; surface that as a disabled affordance.
    private var canDelete: Bool { summaries.count > 1 }

    // MARK: - Content

    private var content: some View {
        List {
            if let active = activeSummary {
                Section {
                    ActiveProfileCard(
                        summary: active,
                        onRename: { renaming = RenameTarget(id: active.id, name: active.name) },
                        onDuplicate: { duplicate(active) },
                        onDelete: canDelete ? { pendingDelete = active } : nil,
                        isBusy: busyIDs.contains(active.id)
                    )
                    .listRowInsets(EdgeInsets(
                        top: Theme.Spacing.xs, leading: Theme.Spacing.sm,
                        bottom: Theme.Spacing.xs, trailing: Theme.Spacing.sm
                    ))
                    .listRowSeparator(.hidden)
                } header: {
                    Text("当前配置")
                }
            }

            Section {
                if otherSummaries.isEmpty {
                    emptyOthersRow
                } else {
                    ForEach(otherSummaries) { summary in
                        ProfileRow(
                            summary: summary,
                            isBusy: busyIDs.contains(summary.id),
                            now: now
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { activate(summary) }
                        .contextMenu { rowMenu(for: summary) }
                        .listRowInsets(EdgeInsets(
                            top: Theme.Spacing.xs, leading: Theme.Spacing.sm,
                            bottom: Theme.Spacing.xs, trailing: Theme.Spacing.sm
                        ))
                    }
                }
            } header: {
                otherListHeader
            } footer: {
                Text("点击其它配置即可切换。切换会用目标配置的订阅与设置重新生成配置，校验通过后重启代理；校验失败则保留当前配置。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        }
        .listStyle(.inset)
        .animation(.easeInOut(duration: 0.15), value: summaries)
        .animation(.easeInOut(duration: 0.15), value: busyIDs)
    }

    private var otherListHeader: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("其它配置")
            CountBadge(count: otherSummaries.count)
            Spacer(minLength: Theme.Spacing.xs)
            Text("共 \(summaries.count) 个配置")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    private var emptyOthersRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.body)
                .foregroundStyle(Theme.Color.tertiaryLabel)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("只有一个配置")
                    .font(Theme.Font.bodyEmphasized)
                    .foregroundStyle(Theme.Color.label)
                Text("新建或复制一个配置，便可在不同订阅与路由方案之间快速切换。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Button("新建配置…") { isCreating = true }
                .buttonStyle(.borderless)
                .font(Theme.Font.caption)
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if isMutating {
                ProgressView().controlSize(.small)
            }
            Button {
                if let active = activeSummary { duplicate(active) }
            } label: {
                Label("复制当前", systemImage: "plus.square.on.square")
            }
            .help("基于当前配置创建一个副本并切换过去")
            .disabled(activeSummary == nil || isMutating)

            Button { isCreating = true } label: {
                Label("新建配置", systemImage: "plus")
            }
            .help("创建一个空白配置并切换过去")
            .disabled(isMutating)
        }
    }

    @ViewBuilder
    private func rowMenu(for summary: ProfileSummary) -> some View {
        Button {
            activate(summary)
        } label: {
            Label("切换到此配置", systemImage: "checkmark.circle")
        }
        .disabled(busyIDs.contains(summary.id))

        Button {
            duplicate(summary)
        } label: {
            Label("复制", systemImage: "plus.square.on.square")
        }

        Button {
            renaming = RenameTarget(id: summary.id, name: summary.name)
        } label: {
            Label("重命名…", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = summary
        } label: {
            Label("删除", systemImage: "trash")
        }
        .disabled(!canDelete)
    }

    // MARK: - Actions

    private func create(named name: String) {
        guard !isMutating else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            await appState.createProfile(named: name)
        }
    }

    private func duplicate(_ summary: ProfileSummary) {
        guard !isMutating, !busyIDs.contains(summary.id) else { return }
        isMutating = true
        busyIDs.insert(summary.id)
        Task {
            defer {
                isMutating = false
                busyIDs.remove(summary.id)
            }
            _ = await appState.duplicateProfile(id: summary.id)
        }
    }

    private func activate(_ summary: ProfileSummary) {
        guard !summary.isActive, !busyIDs.contains(summary.id) else { return }
        busyIDs.insert(summary.id)
        Task {
            defer { busyIDs.remove(summary.id) }
            await appState.switchProfile(id: summary.id)
        }
    }

    private func delete(_ summary: ProfileSummary) {
        pendingDelete = nil
        guard !busyIDs.contains(summary.id) else { return }
        busyIDs.insert(summary.id)
        Task {
            defer { busyIDs.remove(summary.id) }
            await appState.deleteProfile(id: summary.id)
        }
    }

    // MARK: - Local value types

    /// A profile being renamed, identified for the rename sheet.
    private struct RenameTarget: Identifiable {
        let id: UUID
        let name: String
    }
}

// =============================================================================
// MARK: - ActiveProfileCard
// =============================================================================

/// A prominent card for the currently active profile: a leading mode glyph, the
/// name with an "当前" pill, the subscription/node/mode meta line, and an inline
/// action row (复制 / 重命名 / 删除). Distinct from the plain rows below so the
/// user always sees which profile is live at a glance.
private struct ActiveProfileCard: View {
    let summary: ProfileSummary
    let onRename: () -> Void
    let onDuplicate: () -> Void
    /// `nil` when the active profile is the last one (delete is disallowed).
    let onDelete: (() -> Void)?
    let isBusy: Bool

    var body: some View {
        Card(material: .thinMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .fill(Theme.Color.accent.opacity(0.16))
                            .frame(width: 36, height: 36)
                        Image(systemName: ProfilePresentation.modeSymbol(summary.proxyMode))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.Color.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(summary.name)
                                .font(Theme.Font.heading)
                                .foregroundStyle(Theme.Color.label)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            activePill
                        }
                        ProfileMetaLine(summary: summary)
                    }

                    Spacer(minLength: Theme.Spacing.xs)

                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                }

                Divider().opacity(0.5)

                HStack(spacing: Theme.Spacing.sm) {
                    InlineAction(title: "复制", symbol: "plus.square.on.square", action: onDuplicate)
                    InlineAction(title: "重命名", symbol: "pencil", action: onRename)
                    Spacer(minLength: 0)
                    InlineAction(
                        title: "删除",
                        symbol: "trash",
                        tint: Theme.Color.error,
                        action: onDelete ?? {}
                    )
                    .disabled(onDelete == nil)
                    .help(onDelete == nil ? "至少保留一个配置" : "删除此配置")
                }
            }
        }
    }

    private var activePill: some View {
        Text("当前")
            .font(Theme.Font.caption2.weight(.semibold))
            .foregroundStyle(Theme.Color.accent)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, 2)
            .background(Theme.Color.accent.opacity(0.16), in: Capsule())
    }
}

/// A small inline text+icon button used in the active-profile action row.
private struct InlineAction: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.Color.secondaryLabel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: symbol).font(.caption)
                Text(title).font(Theme.Font.caption.weight(.medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.Radius.small)
    }
}

// =============================================================================
// MARK: - ProfileRow
// =============================================================================

/// One non-active profile entry: a leading mode glyph, the name, the
/// subscription/node/mode meta line and relative "更新于" time, and a trailing
/// "切换" affordance (replaced by a spinner while a switch is in flight). Click
/// anywhere on the row to switch to it.
private struct ProfileRow: View {
    let summary: ProfileSummary
    let isBusy: Bool
    let now: Date

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: ProfilePresentation.modeSymbol(summary.proxyMode))
                .font(.body)
                .foregroundStyle(Theme.Color.secondaryLabel)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(Theme.Font.bodyEmphasized)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProfileMetaLine(summary: summary, now: now)
            }

            Spacer(minLength: Theme.Spacing.sm)

            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                switchHint
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .hoverHighlight()
    }

    private var switchHint: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text("切换")
                .font(Theme.Font.caption.weight(.medium))
            Image(systemName: "arrow.right.circle")
                .font(.caption)
        }
        .foregroundStyle(Theme.Color.accent)
    }
}

// =============================================================================
// MARK: - ProfileMetaLine
// =============================================================================

/// The shared meta line under a profile name: a mode badge, subscription count,
/// node count, and — when a clock is supplied — a relative "更新于" time.
private struct ProfileMetaLine: View {
    let summary: ProfileSummary
    /// When `nil`, the relative time is omitted (the active card has no clock).
    var now: Date?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ModeBadge(mode: summary.proxyMode)
            metaItem(symbol: "antenna.radiowaves.left.and.right", text: "\(summary.subscriptionCount)")
            metaItem(symbol: "circle.grid.3x3.fill", text: "\(summary.nodeCount)")
            if now != nil {
                dot
                Text(updatedText)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        }
    }

    private func metaItem(symbol: String, text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Color.secondaryLabel)
            .labelStyle(.titleAndIcon)
    }

    private var dot: some View {
        Text("·")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Color.tertiaryLabel)
    }

    private var updatedText: String {
        let relative = summary.updatedAt.formatted(.relative(presentation: .named))
        return "更新于 \(relative)"
    }
}

/// A compact proxy-mode badge (系统代理 / TUN 全局).
private struct ModeBadge: View {
    let mode: ProxyMode

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: ProfilePresentation.modeSymbol(mode))
                .font(.caption2.weight(.semibold))
            Text(mode.displayName)
                .font(Theme.Font.caption2.weight(.medium))
        }
        .foregroundStyle(Theme.Color.info)
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, 2)
        .background(Theme.Color.info.opacity(0.12), in: Capsule())
    }
}

// =============================================================================
// MARK: - ProfilePresentation
// =============================================================================

/// Shared presentation helpers for profiles (mode → SF Symbol), so the card,
/// row, and badge all read from one source of truth.
private enum ProfilePresentation {
    static func modeSymbol(_ mode: ProxyMode) -> String {
        switch mode {
        case .systemProxy: return "network"
        case .tun: return "point.3.filled.connected.trianglepath.dotted"
        }
    }
}

// =============================================================================
// MARK: - ProfileNameSheet
// =============================================================================

/// A small modal for naming a profile, reused for both create and rename.
/// Commits a trimmed, non-empty name on confirm; empty input is rejected so a
/// profile can never lose its label. `AppState` de-duplicates the name on create.
private struct ProfileNameSheet: View {
    let title: String
    let subtitle: String
    let confirmTitle: String
    let initialName: String
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(
        title: String,
        subtitle: String,
        confirmTitle: String,
        initialName: String,
        onCommit: @escaping (String) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.confirmTitle = confirmTitle
        self.initialName = initialName
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.Color.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Color.label)
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                }
            }

            TextField("配置名称", text: $name, prompt: Text("配置名称"))
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.body)
                .onSubmit(commit)

            HStack(spacing: Theme.Spacing.sm) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 380)
        .background(.regularMaterial)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}
