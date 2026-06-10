import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - SubscriptionsView
// =============================================================================

/// The 订阅 (Subscriptions) management surface: a native list of every imported
/// subscription with its node count, last-updated time, and per-subscription
/// health, plus add / manual-刷新 / 全部刷新 / 重命名 / 删除 and an auto-update
/// toggle with an interval picker.
///
/// This is a self-contained, window-ready root. It owns only its own transient
/// UI state and commits every mutation through `AppState`'s subscription
/// surface (`addSubscription` / `refreshSubscription(id:)` /
/// `refreshAllSubscriptions` / `renameSubscription(id:to:)` /
/// `removeSubscription(id:)` / `setAutoUpdate(enabled:intervalMinutes:)`). It
/// can be hosted as a Dashboard sidebar item (embed `SubscriptionsView()` in the
/// detail pane) or in a dedicated `Window("订阅", id: ...)`.
///
/// Build-agent wiring note: to surface this as a Dashboard sidebar entry, add a
/// `case subscriptions` to `DashboardSection` (title "订阅", a routing-style
/// section so it owns its own navigation title + toolbar — set `isRoutingSection`
/// to include it), list it in a new "订阅" sidebar `Section`, and return
/// `SubscriptionsView()` from `DashboardView.detail`. The view already declares
/// `.navigationTitle("订阅")` and its own toolbar, matching the routing panes.
struct SubscriptionsView: View {
    @EnvironmentObject private var appState: AppState

    /// Whether the "add subscription" sheet is presented.
    @State private var isAdding = false
    /// Ids currently being refreshed, so each row can show a spinner and the
    /// 全部刷新 button can reflect an in-flight batch without blocking the UI.
    @State private var refreshingIDs: Set<UUID> = []
    /// `true` while a 全部刷新 batch is in flight.
    @State private var isRefreshingAll = false
    /// The subscription being renamed in the inline rename sheet, or `nil`.
    @State private var renaming: RenameTarget?
    /// The subscription pending delete confirmation, or `nil`.
    @State private var pendingDelete: Subscription?
    /// Transient banner describing the most recent refresh/import outcome.
    @State private var notice: Notice?
    /// Re-evaluated once a minute so the relative "更新于" times stay fresh.
    @State private var now = Date()

    private let clockTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if subscriptions.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle("订阅")
        .toolbar { toolbarContent }
        .sheet(isPresented: $isAdding) {
            // Reuse the polished import sheet as the "add" affordance: it accepts
            // an http(s) URL or a local file path and reports parser warnings.
            ImportSubscriptionView()
                .environmentObject(appState)
        }
        .sheet(item: $renaming) { target in
            RenameSubscriptionSheet(initialName: target.name) { newName in
                appState.renameSubscription(id: target.id, to: newName)
            }
        }
        .confirmationDialog(
            "删除订阅「\(pendingDelete?.name ?? "")」？",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = pendingDelete { delete(target) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除该订阅及其全部节点。若它正在为运行中的代理提供所选节点，代理会自动切换并重启。")
        }
        .onReceive(clockTimer) { now = $0 }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: - Derived state

    private var subscriptions: [Subscription] { appState.subscriptions }

    private var totalNodeCount: Int {
        subscriptions.reduce(0) { $0 + $1.nodes.count }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    // MARK: - Content

    private var content: some View {
        List {
            if let notice {
                Section {
                    NoticeBanner(notice: notice) { self.notice = nil }
                        .listRowInsets(EdgeInsets(
                            top: Theme.Spacing.xs, leading: Theme.Spacing.sm,
                            bottom: Theme.Spacing.xs, trailing: Theme.Spacing.sm
                        ))
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                ForEach(subscriptions) { subscription in
                    SubscriptionRow(
                        subscription: subscription,
                        isRefreshing: refreshingIDs.contains(subscription.id),
                        now: now
                    )
                    .contentShape(Rectangle())
                    .contextMenu { rowMenu(for: subscription) }
                    .listRowInsets(EdgeInsets(
                        top: Theme.Spacing.xs, leading: Theme.Spacing.sm,
                        bottom: Theme.Spacing.xs, trailing: Theme.Spacing.sm
                    ))
                }
            } header: {
                listHeader
            }

            autoUpdateSection
        }
        .listStyle(.inset)
        .animation(.easeInOut(duration: 0.15), value: subscriptions)
        .animation(.easeInOut(duration: 0.15), value: refreshingIDs)
    }

    private var listHeader: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("订阅")
            CountBadge(count: subscriptions.count)
            Spacer(minLength: Theme.Spacing.xs)
            Text("\(totalNodeCount) 个节点")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - Auto-update controls

    private var autoUpdateSection: some View {
        Section {
            AutoUpdateControls(
                enabled: appState.preferences.subscriptionAutoUpdateEnabled,
                intervalMinutes: appState.preferences.subscriptionAutoUpdateMinutes,
                onChange: applyAutoUpdate
            )
            .listRowInsets(EdgeInsets(
                top: Theme.Spacing.xs, leading: Theme.Spacing.sm,
                bottom: Theme.Spacing.xs, trailing: Theme.Spacing.sm
            ))
        } header: {
            Text("自动更新")
        } footer: {
            Text("开启后将按所选间隔在后台自动刷新全部订阅。代理切换或重启期间会跳过当次刷新。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Theme.Color.accent.opacity(0.7))
            VStack(spacing: Theme.Spacing.xxs) {
                Text("尚未添加订阅")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.label)
                Text("从 Clash 订阅链接或本地 YAML 文件导入节点。\n可添加多个订阅，并开启后台自动更新。")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: { isAdding = true }) {
                Label("添加订阅", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: refreshAll) {
                if isRefreshingAll {
                    ProgressView().controlSize(.small)
                } else {
                    Label("全部刷新", systemImage: "arrow.clockwise")
                }
            }
            .help("重新下载并解析全部订阅")
            .disabled(subscriptions.isEmpty || isRefreshingAll)

            Button(action: { isAdding = true }) {
                Label("添加订阅", systemImage: "plus")
            }
            .help("从订阅链接或本地文件添加")
        }
    }

    @ViewBuilder
    private func rowMenu(for subscription: Subscription) -> some View {
        Button {
            refresh(subscription)
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
        }
        .disabled(refreshingIDs.contains(subscription.id))

        Button {
            renaming = RenameTarget(id: subscription.id, name: subscription.name)
        } label: {
            Label("重命名…", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = subscription
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func refresh(_ subscription: Subscription) {
        guard !refreshingIDs.contains(subscription.id) else { return }
        refreshingIDs.insert(subscription.id)
        Task {
            defer { refreshingIDs.remove(subscription.id) }
            do {
                let warnings = try await appState.refreshSubscription(id: subscription.id)
                notice = .success(
                    message: "已刷新「\(subscription.name)」。",
                    warnings: warnings
                )
            } catch {
                let message = (error as? AppError)?.message ?? error.localizedDescription
                notice = .failure(message: "刷新「\(subscription.name)」失败：\(message)")
            }
        }
    }

    private func refreshAll() {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        let ids = Set(subscriptions.map(\.id))
        refreshingIDs.formUnion(ids)
        Task {
            defer {
                isRefreshingAll = false
                refreshingIDs.subtract(ids)
            }
            let warnings = await appState.refreshAllSubscriptions()
            notice = .success(message: "已刷新全部订阅。", warnings: warnings)
        }
    }

    private func delete(_ subscription: Subscription) {
        pendingDelete = nil
        Task {
            await appState.removeSubscription(id: subscription.id)
            notice = .success(message: "已删除「\(subscription.name)」。", warnings: [])
        }
    }

    private func applyAutoUpdate(enabled: Bool, intervalMinutes: Int) {
        Task {
            await appState.setAutoUpdate(enabled: enabled, intervalMinutes: intervalMinutes)
        }
    }

    // MARK: - Local value types

    /// A subscription being renamed, identified for the rename sheet.
    private struct RenameTarget: Identifiable {
        let id: UUID
        let name: String
    }
}

// =============================================================================
// MARK: - SubscriptionRow
// =============================================================================

/// One row in the subscription list: a leading health glyph, the name + source
/// host, node count and relative "更新于" time, and a trailing health pill (with
/// an inline spinner while refreshing).
private struct SubscriptionRow: View {
    let subscription: Subscription
    let isRefreshing: Bool
    let now: Date

    private var health: SubscriptionHealth {
        SubscriptionHealth(for: subscription)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: health.symbolName)
                .font(.body)
                .foregroundStyle(health.tint)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(Theme.Font.bodyEmphasized)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                metaLine
            }

            Spacer(minLength: Theme.Spacing.sm)

            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                healthPill
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Label("\(subscription.nodes.count)", systemImage: "circle.grid.3x3.fill")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
                .labelStyle(.titleAndIcon)
            Text("·")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.tertiaryLabel)
            Text(updatedText)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
            Text("·")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.tertiaryLabel)
            Text(sourceText)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.tertiaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// A compact, relative "更新于 …" line, or a placeholder when never refreshed.
    private var updatedText: String {
        guard let lastUpdated = subscription.lastUpdated else { return "尚未更新" }
        let relative = lastUpdated.formatted(.relative(presentation: .named))
        return "更新于 \(relative)"
    }

    /// The source host (for http(s)) or file name (for local paths).
    private var sourceText: String {
        if subscription.url.isFileURL {
            return subscription.url.lastPathComponent
        }
        return subscription.url.host ?? subscription.url.absoluteString
    }

    private var healthPill: some View {
        HStack(spacing: Theme.Spacing.xxs + 1) {
            Image(systemName: health.symbolName)
                .font(.caption2.weight(.semibold))
            Text(health.title)
                .font(Theme.Font.caption.weight(.medium))
        }
        .foregroundStyle(health.tint)
        .padding(.horizontal, Theme.Spacing.xs + 1)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(health.tint.opacity(0.12), in: Capsule())
        .help(health.help)
    }
}

// =============================================================================
// MARK: - SubscriptionHealth
// =============================================================================

/// Per-subscription health, derived purely from its node count and staleness.
/// `empty` (no nodes parsed) is an error; a refresh older than a day is a
/// degraded warning; otherwise healthy.
private struct SubscriptionHealth {
    let title: String
    let help: String
    let tint: Color
    let symbolName: String

    /// Subscriptions not refreshed within this window read as "陈旧".
    private static let staleThreshold: TimeInterval = 24 * 60 * 60

    init(for subscription: Subscription) {
        if subscription.nodes.isEmpty {
            title = "无节点"
            help = "该订阅没有可用节点，请检查链接是否有效后重新刷新。"
            tint = Theme.Color.error
            symbolName = "exclamationmark.triangle.fill"
            return
        }
        if let lastUpdated = subscription.lastUpdated,
           Date().timeIntervalSince(lastUpdated) > Self.staleThreshold {
            title = "陈旧"
            help = "距上次更新已超过一天，建议刷新以获取最新节点。"
            tint = Theme.Color.warning
            symbolName = "clock.badge.exclamationmark.fill"
            return
        }
        if subscription.lastUpdated == nil {
            title = "待更新"
            help = "尚未刷新过，点击刷新以下载最新节点。"
            tint = Theme.Color.warning
            symbolName = "clock.fill"
            return
        }
        title = "正常"
        help = "订阅健康，节点已是最新。"
        tint = Theme.Color.active
        symbolName = "checkmark.circle.fill"
    }
}

// =============================================================================
// MARK: - AutoUpdateControls
// =============================================================================

/// The grouped auto-update controls: a toggle and an interval picker. The picker
/// is disabled while auto-update is off. Both commit immediately via `onChange`,
/// which `AppState.setAutoUpdate` clamps to a safe minimum interval.
private struct AutoUpdateControls: View {
    let enabled: Bool
    let intervalMinutes: Int
    let onChange: (_ enabled: Bool, _ intervalMinutes: Int) -> Void

    /// The user-selectable intervals (minutes). The smallest matches
    /// `AppPreferences.minAutoUpdateMinutes`; longer options cover daily refresh.
    private static let intervalOptions: [Int] = [15, 30, 60, 120, 360, 720, 1440]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Toggle(isOn: toggleBinding) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("自动更新订阅")
                            .font(Theme.Font.bodyEmphasized)
                            .foregroundStyle(Theme.Color.label)
                        Text("在后台按间隔自动刷新全部订阅")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Theme.Color.accent)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: Theme.Spacing.sm) {
                Text("更新间隔")
                    .font(Theme.Font.body)
                    .foregroundStyle(enabled ? Theme.Color.label : Theme.Color.secondaryLabel)
                Spacer(minLength: Theme.Spacing.xs)
                Picker("更新间隔", selection: intervalBinding) {
                    ForEach(Self.intervalOptions, id: \.self) { minutes in
                        Text(Self.label(forMinutes: minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!enabled)
            }
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { onChange($0, intervalMinutes) }
        )
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { resolvedSelection },
            set: { onChange(enabled, $0) }
        )
    }

    /// Maps the persisted interval onto an offered option, snapping an unlisted
    /// value (e.g. a legacy 45) to the nearest available choice so the menu
    /// always shows a concrete selection.
    private var resolvedSelection: Int {
        if Self.intervalOptions.contains(intervalMinutes) { return intervalMinutes }
        return Self.intervalOptions.min(by: {
            abs($0 - intervalMinutes) < abs($1 - intervalMinutes)
        }) ?? Self.intervalOptions[2]
    }

    /// Human label for an interval in minutes, e.g. `30 分钟`, `2 小时`, `1 天`.
    private static func label(forMinutes minutes: Int) -> String {
        if minutes % 1440 == 0 {
            return "\(minutes / 1440) 天"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60) 小时"
        }
        return "\(minutes) 分钟"
    }
}

// =============================================================================
// MARK: - RenameSubscriptionSheet
// =============================================================================

/// A small modal for renaming a subscription. Commits a trimmed, non-empty name
/// on confirm; empty input is rejected so the row can never lose its label.
private struct RenameSubscriptionSheet: View {
    let initialName: String
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(initialName: String, onCommit: @escaping (String) -> Void) {
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
                Image(systemName: "pencil.line")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.Color.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("重命名订阅")
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Color.label)
                    Text("设置一个便于识别的名称")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                }
            }

            TextField("订阅名称", text: $name, prompt: Text("订阅名称"))
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.body)
                .onSubmit(commit)

            HStack(spacing: Theme.Spacing.sm) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: commit)
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

// =============================================================================
// MARK: - NoticeBanner
// =============================================================================

/// A dismissible result banner shown above the list after a refresh / delete:
/// a status glyph + headline, with a disclosure of parser warnings when present.
private struct NoticeBanner: View {
    let notice: Notice
    let onDismiss: () -> Void

    @State private var showWarnings = false

    var body: some View {
        Card(material: .thinMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: notice.symbolName)
                        .foregroundStyle(notice.tint)
                    Text(notice.message)
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(Theme.Color.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Spacing.xs)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
                }
                if !notice.warnings.isEmpty {
                    DisclosureGroup(isExpanded: $showWarnings) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(notice.warnings.enumerated()), id: \.offset) { _, warning in
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
                        Text("\(notice.warnings.count) 条提示")
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(Theme.Color.warning)
                    }
                }
            }
        }
    }
}

/// The outcome surfaced by `NoticeBanner` after a subscription operation.
private struct Notice: Equatable {
    let message: String
    let warnings: [String]
    let isError: Bool

    static func success(message: String, warnings: [String]) -> Notice {
        Notice(message: message, warnings: warnings, isError: false)
    }

    static func failure(message: String) -> Notice {
        Notice(message: message, warnings: [], isError: true)
    }

    var symbolName: String {
        isError ? "xmark.octagon.fill" : "checkmark.circle.fill"
    }

    var tint: Color {
        isError ? Theme.Color.error : Theme.Color.active
    }
}
