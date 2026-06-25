import AppKit
import LinkoKit
import SwiftUI

// =============================================================================
// MARK: - ImportRulesView
// =============================================================================

/// A modal sheet for migrating routing rules from an existing Surge profile
/// (`[Rule]` section) or a Clash YAML `rules:` list. Accepts pasted text or a
/// file chosen via `NSOpenPanel`, parses with the LinkoKit importers, previews
/// the result (counts, unresolved policy names, per-line warnings), then hands
/// the parsed rules back to the caller to merge into the live config.
struct ImportRulesView: View {
    @Environment(\.dismiss) private var dismiss

    /// The set of outbound tags that already resolve (built-ins, groups, nodes),
    /// used to flag imported policy names that won't map to anything.
    let existingPolicyTags: Set<String>
    /// Hands the parsed rules and a summary back to the caller for merging.
    let onImport: ([RoutingRule], ImportSummary) -> Void

    @State private var sourceText = ""
    @State private var format: ImportFormat = .auto
    @State private var preview: Preview?

    /// Which importer to run. `.auto` sniffs the text for a `[Rule]` header or
    /// a YAML `rules:` key.
    private enum ImportFormat: String, CaseIterable, Identifiable {
        case auto, surge, clash
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "自动识别"
            case .surge: return "Surge"
            case .clash: return "Clash"
            }
        }
    }

    /// Parsed-but-not-yet-merged result, shown in the preview area.
    private struct Preview {
        let rules: [RoutingRule]
        let referencedPolicies: [String]
        let unresolvedPolicies: [String]
        let warnings: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    formatPicker
                    inputCard
                    if let preview {
                        previewCard(preview)
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.Color.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("导入规则")
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.Color.label)
                Text("从 Surge 或 Clash 配置迁移路由规则")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Format picker

    private var formatPicker: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Picker("来源格式", selection: $format) {
                ForEach(ImportFormat.allCases) { fmt in
                    Text(fmt.title).tag(fmt)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: format) { _, _ in if !sourceText.isEmpty { parse() } }
            Spacer()
            Button {
                openFile()
            } label: {
                Label("从文件…", systemImage: "folder")
            }
        }
    }

    // MARK: - Input

    private var inputCard: some View {
        Card(material: .regularMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                SectionHeader("粘贴规则文本", symbolName: "doc.plaintext")
                TextEditor(text: $sourceText)
                    .font(Theme.Font.monoSmall)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.xs)
                    .background(Theme.Color.hover.opacity(0.5),
                               in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if sourceText.isEmpty {
                            Text("DOMAIN-SUFFIX,google.com,Proxy\nIP-CIDR,192.168.0.0/16,DIRECT\n…")
                                .font(Theme.Font.monoSmall)
                                .foregroundStyle(Theme.Color.tertiaryLabel)
                                .padding(Theme.Spacing.sm)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: sourceText) { _, _ in parse() }
                Text("支持完整配置文件或仅规则行。Surge `[Rule]` 段与 Clash `rules:` 列表均可。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
            }
        }
    }

    // MARK: - Preview

    private func previewCard(_ preview: Preview) -> some View {
        Card(material: .thinMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Label("\(preview.rules.count) 条可导入", systemImage: "checkmark.circle.fill")
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(preview.rules.isEmpty ? Theme.Color.secondaryLabel : Theme.Color.active)
                    Spacer()
                    if !preview.referencedPolicies.isEmpty {
                        Text("引用 \(preview.referencedPolicies.count) 个策略")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                    }
                }

                if !preview.unresolvedPolicies.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Label("以下策略名在当前配置中不存在，导入后需手动重新指定目标：",
                              systemImage: "questionmark.circle.fill")
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(Theme.Color.warning)
                        FlowText(items: preview.unresolvedPolicies)
                    }
                }

                if !preview.warnings.isEmpty {
                    Divider()
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("\(preview.warnings.count) 条跳过 / 提示")
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(Theme.Color.warning)
                        Spacer()
                        CountBadge(count: preview.warnings.count)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
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
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Spacer()
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("导入 \(preview?.rules.count ?? 0) 条") { commit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled((preview?.rules.isEmpty ?? true))
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Parsing

    /// Re-runs the importer for the current text + format and refreshes the
    /// preview. Cheap and offline, so it runs on every keystroke.
    private func parse() {
        let text = sourceText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preview = nil
            return
        }
        let result = runImporter(on: text)
        let unresolved = result.referencedPolicies.filter { !existingPolicyTags.contains($0) }
        preview = Preview(
            rules: result.rules,
            referencedPolicies: result.referencedPolicies,
            unresolvedPolicies: unresolved,
            warnings: result.warnings
        )
    }

    /// Selects and runs the appropriate importer. `.auto` chooses Clash when the
    /// text reads as YAML (`rules:` key or `- TYPE,...` list items) and Surge
    /// otherwise, falling back to whichever yields rules.
    private func runImporter(on text: String) -> RuleImportResult {
        switch format {
        case .surge:
            return SurgeRuleImporter().importSurgeRules(text)
        case .clash:
            return ClashRuleImporter().importClashRules(text)
        case .auto:
            if looksLikeClash(text) {
                let clash = ClashRuleImporter().importClashRules(text)
                if !clash.rules.isEmpty { return clash }
            }
            let surge = SurgeRuleImporter().importSurgeRules(text)
            if !surge.rules.isEmpty { return surge }
            // Last resort: try the other importer so a near-miss still previews.
            return ClashRuleImporter().importClashRules(text)
        }
    }

    /// Heuristic for `.auto`: a `rules:` mapping key or YAML list markers signal
    /// Clash; a `[Rule]` header signals Surge.
    private func looksLikeClash(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "rules:" }) {
            return true
        }
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[Rule]") }) {
            return false
        }
        // Bare list of "- DOMAIN,..." items reads as Clash YAML.
        return lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
    }

    // MARK: - File picker

    private func openFile() {
        let panel = NSOpenPanel()
        panel.title = "选择规则文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.text, .yaml, .plainText, .data]
        if panel.runModal() == .OK,
           let url = panel.url,
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            // Bias auto-detection by extension when the user picked a file.
            if format == .auto {
                let ext = url.pathExtension.lowercased()
                if ext == "yaml" || ext == "yml" { format = .clash }
                else if ext == "conf" || ext == "ini" { format = .surge }
            }
            sourceText = contents
            parse()
        }
    }

    // MARK: - Commit

    private func commit() {
        guard let preview, !preview.rules.isEmpty else { return }
        let summary = ImportSummary(
            importedCount: preview.rules.count,
            unresolvedPolicies: preview.unresolvedPolicies,
            warnings: preview.warnings
        )
        onImport(preview.rules, summary)
        dismiss()
    }
}

// =============================================================================
// MARK: - FlowText
// =============================================================================

/// A simple wrapping row of monospace policy-name chips. Avoids a horizontal
/// scroll for the (usually short) list of unresolved policy names.
private struct FlowText: View {
    let items: [String]

    var body: some View {
        // A LazyVGrid with adaptive columns gives a clean wrap without a custom
        // layout, which is plenty for a handful of short policy names.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 80, maximum: 200), spacing: Theme.Spacing.xxs, alignment: .leading)],
            alignment: .leading,
            spacing: Theme.Spacing.xxs
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Theme.Color.warning.opacity(0.14), in: Capsule())
            }
        }
    }
}
