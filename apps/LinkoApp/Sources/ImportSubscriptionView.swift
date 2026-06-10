import LinkoKit
import SwiftUI

/// Card-based window for importing a Clash YAML subscription. Accepts an
/// http(s) URL or a local file path, shows import progress, and lists any
/// parser warnings (skipped nodes) as a clean, icon-led result list.
struct ImportSubscriptionView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var sourceText = ""
    @State private var phase: Phase = .idle

    /// Import lifecycle, driving both the button and the result area.
    private enum Phase: Equatable {
        case idle
        case importing
        case failed(String)
        case finished(imported: Int, warnings: [String])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header
            inputCard
            resultArea
            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
        .frame(minHeight: 360)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.Color.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("导入订阅")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.label)
                Text("从 Clash 订阅链接或本地文件导入节点")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        }
    }

    // MARK: - Input

    private var inputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader("订阅来源", symbolName: "link")
                TextField(
                    "",
                    text: $sourceText,
                    prompt: Text("https://example.com/sub  或  /路径/clash.yaml")
                )
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.mono)
                .disabled(isImporting)
                .onSubmit(startImport)
                Text("支持 http(s) 链接与本地文件路径（YAML）。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
            }
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultArea: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .importing:
            Card(material: .thinMaterial) {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在下载并解析订阅…")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                }
            }
        case .failed(let message):
            Card(material: .thinMaterial) {
                Label {
                    Text(message)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.label)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Theme.Color.error)
                }
            }
        case .finished(let imported, let warnings):
            ResultCard(imported: imported, warnings: warnings)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Spacer()
            Button(isFinished ? "完成" : "取消") { dismiss() }
                .keyboardShortcut(isFinished ? .defaultAction : .cancelAction)
            if !isFinished {
                Button(action: startImport) {
                    HStack(spacing: Theme.Spacing.xs) {
                        if isImporting {
                            ProgressView().controlSize(.small)
                        }
                        Text(isImporting ? "导入中…" : "导入")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isImporting || trimmedSource.isEmpty)
            }
        }
    }

    // MARK: - State helpers

    private var trimmedSource: String {
        sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isImporting: Bool {
        phase == .importing
    }

    private var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    // MARK: - Actions

    private func startImport() {
        guard !isImporting, !trimmedSource.isEmpty else { return }
        phase = .importing
        Task {
            do {
                let warnings = try await appState.importSubscription(urlString: trimmedSource)
                let imported = appState.allNodes.count
                phase = .finished(imported: imported, warnings: warnings)
            } catch {
                let message = (error as? AppError)?.message ?? error.localizedDescription
                phase = .failed(message)
            }
        }
    }
}

// =============================================================================
// MARK: - ResultCard
// =============================================================================

/// Successful-import summary: a green confirmation line plus, when present, a
/// scrollable list of skipped-node warnings rendered icon-first.
private struct ResultCard: View {
    let imported: Int
    let warnings: [String]

    var body: some View {
        Card(material: .thinMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label {
                    Text("导入成功，当前共 \(imported) 个节点。")
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(Theme.Color.label)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Color.active)
                }

                if !warnings.isEmpty {
                    Divider()
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("已跳过 \(warnings.count) 个无法识别的节点")
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(Theme.Color.warning)
                        Spacer()
                        CountBadge(count: warnings.count)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                WarningRow(text: warning)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
    }
}

/// A single parser warning line: a small warning glyph and the message text.
private struct WarningRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.Color.warning)
            Text(text)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.secondaryLabel)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
