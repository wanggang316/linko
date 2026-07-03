import AppKit
import LinkoKit
import SwiftUI

/// The「为当前网页添加规则」window: renders the capture outcome and the full
/// quick-add form — candidate scopes parsed from the captured page, a
/// deliberately narrow rule-type choice, the normalized matcher value, and
/// the outbound target. Saving prepends the rule to
/// `preferences.routing.rules` through `AppState.updatePreferences` (the
/// existing debounced reload applies it to a running core; with the proxy
/// stopped it persists silently). Cancelling — button, Esc, or the window's
/// close control — persists nothing.
struct QuickAddRuleView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Form state rebuilt from every capture outcome; `nil` while a capture
    /// is in flight (a re-trigger resets the window to the new capture).
    @State private var form: QuickAddFormModel?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
        .frame(minHeight: 320)
        .background(.regularMaterial)
        .onAppear { rebuildForm(for: appState.quickAddCapture) }
        .onChange(of: appState.quickAddCapture) { _, newState in
            rebuildForm(for: newState)
        }
    }

    // MARK: - Derived state

    /// The outbound targets a quick-add rule can point at, rebuilt from the
    /// live config and node list exactly like `RulesView` (same deterministic
    /// tag dedup the config builder uses).
    private var targets: RoutingTargets {
        let nodes = appState.allNodes
        let tags = Self.tagBuilder.outboundTags(for: nodes)
        return RoutingTargets(routing: appState.preferences.routing, nodes: nodes, nodeTags: tags)
    }

    /// A stateless tag resolver shared across renders; `outboundTags(for:)`
    /// is a pure function of its input.
    private static let tagBuilder = SingBoxConfigBuilder()

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "plus.circle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.Color.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("添加规则")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.label)
                Text("基于当前网页快速创建分流规则")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch appState.quickAddCapture {
        case .capturing:
            capturingCard
        case .captured(let urlString):
            formCard(capturedHost: Self.displayHost(from: urlString), guidance: nil)
        case .manual(let guidance):
            formCard(capturedHost: nil, guidance: guidance)
        }
    }

    private var capturingCard: some View {
        Card(material: .thinMaterial) {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取当前网页地址…")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        }
    }

    /// The form fields once a capture settled. Falls back to the progress
    /// card for the one render before `onAppear` builds the form.
    @ViewBuilder
    private func formCard(capturedHost: String?, guidance: QuickAddCapture.Guidance?) -> some View {
        if let formBinding = Binding($form) {
            QuickAddFormFields(
                form: formBinding,
                targets: targets,
                capturedHost: capturedHost,
                guidance: guidance,
                onSubmit: save
            )
        } else {
            capturingCard
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let problem = form?.validationProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
                    .lineLimit(1)
            }
            Spacer()
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("添加") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(form == nil || form?.validationProblem != nil)
        }
    }

    // MARK: - Actions

    /// Rebuilds the form for a capture outcome: progress carries no form, a
    /// captured page prefills from its URL, and manual mode starts empty. The
    /// default target is `RoutingTargets.defaultTag` — never reject.
    private func rebuildForm(for state: QuickAddCaptureState) {
        switch state {
        case .capturing:
            form = nil
        case .captured(let urlString):
            form = QuickAddFormModel(capturedInput: urlString, defaultTarget: targets.defaultTag)
        case .manual:
            form = QuickAddFormModel(capturedInput: nil, defaultTarget: targets.defaultTag)
        }
    }

    /// Prepends the committed rule to the routing rules and closes the
    /// window. `commitRule()` is idempotent (`nil` after the first success),
    /// so a repeated Return press — the field's onSubmit plus the default
    /// button — can never insert twice.
    private func save() {
        guard let rule = form?.commitRule() else { return }
        var preferences = appState.preferences
        preferences.routing.rules.insert(rule, at: 0)
        let updated = preferences
        Task { await appState.updatePreferences(updated) }
        dismiss()
    }

    // MARK: - Helpers

    /// The captured page reduced to its host for display; falls back to the
    /// raw string when it carries no parseable host (shown, never logged).
    private static func displayHost(from urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }
}

// =============================================================================
// MARK: - QuickAddFormFields
// =============================================================================

/// The form body: capture/guidance context, candidate scopes, the segmented
/// type choice, the matcher value, and the outbound target menu. Every
/// control carries a visible text label; long values truncate in the middle
/// instead of breaking the fixed-width layout (the saved value stays
/// complete).
private struct QuickAddFormFields: View {
    @Binding var form: QuickAddFormModel
    let targets: RoutingTargets
    let capturedHost: String?
    let guidance: QuickAddCapture.Guidance?
    let onSubmit: () -> Void

    var body: some View {
        Card(material: .thinMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                contextHeader
                if !form.candidates.isEmpty {
                    candidateField
                }
                typeField
                valueField
                targetField
            }
        }
    }

    // MARK: - Context

    /// What sits above the fields: the captured host (plus a note when it
    /// yielded no candidates), or the failure guidance that preceded manual
    /// mode. A plain manual open shows neither.
    @ViewBuilder
    private var contextHeader: some View {
        if let capturedHost {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Color.active)
                Text("已捕获")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
                Text(capturedHost)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.label)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let problem = form.prefillProblem {
                infoRow(problem)
            }
            Divider().opacity(0.5)
        } else if let guidance {
            infoRow(guidance.message)
            if guidance.offersAutomationSettings {
                Button("打开系统设置 › 隐私与安全性 › 自动化") {
                    openAutomationSettings()
                }
                .buttonStyle(.link)
                .font(Theme.Font.caption)
            }
            Divider().opacity(0.5)
        }
    }

    private func infoRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "info.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.info)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Candidates

    private var candidateField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            fieldLabel("匹配范围")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(form.candidates, id: \.self) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    private func candidateRow(_ candidate: DomainCandidate) -> some View {
        let isSelected = form.selectedCandidate == candidate
        return Button {
            form.selectCandidate(candidate)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.Color.accent : Theme.Color.tertiaryLabel)
                Text(candidate.value)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.xs)
                Text(candidate.ruleType.displayName)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
            .padding(.vertical, Theme.Spacing.xxs)
            .padding(.horizontal, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Theme.Color.hover : SwiftUI.Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        )
        .accessibilityLabel("\(candidate.ruleType.displayName) \(candidate.value)")
    }

    // MARK: - Type / value / target

    private var typeField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            fieldLabel("匹配类型")
            Picker("匹配类型", selection: typeBinding) {
                ForEach(form.availableTypes, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var typeBinding: Binding<RuleType> {
        Binding(get: { form.ruleType }, set: { form.selectType($0) })
    }

    private var valueField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            fieldLabel("匹配值")
            TextField(
                "匹配值",
                text: Binding(get: { form.value }, set: { form.updateValue($0) }),
                prompt: Text(form.ruleType.valuePlaceholder)
            )
            .textFieldStyle(.roundedBorder)
            .font(Theme.Font.mono)
            .labelsHidden()
            .onSubmit(onSubmit)
        }
    }

    private var targetField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            fieldLabel("出站目标")
            Menu {
                TargetMenuItems(
                    targets: targets,
                    allowsReject: true,
                    selectedTag: form.targetTag,
                    onSelect: { form.targetTag = $0 }
                )
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: targets.resolve(form.targetTag).symbolName)
                        .foregroundStyle(Theme.Color.accent)
                    Text(targets.resolve(form.targetTag).displayName)
                        .foregroundStyle(Theme.Color.label)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Theme.Color.tertiaryLabel)
                }
            }
            .menuStyle(.borderlessButton)
        }
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption.weight(.medium))
            .foregroundStyle(Theme.Color.secondaryLabel)
    }

    private func openAutomationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
