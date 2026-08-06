import LinkoKit
import SwiftUI

/// Card-based window for importing nodes. Accepts a subscription URL / local
/// file (Clash YAML, a Base64 V2Ray subscription, or share links) or pasted
/// node link(s); auto-detects the format, shows progress, and lists any parser
/// warnings (skipped nodes) as a clean, icon-led result list.
struct ImportSubscriptionView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var sourceText: String
    @State private var phase: Phase

    /// Import lifecycle, driving both the button and the result area.
    enum Phase: Equatable {
        case idle
        case importing
        case failed(String)
        case finished(summary: String, warnings: [String])
    }

    /// The window always opens on an empty, idle form. The parameters exist so
    /// the sizing tests can render a phase that is otherwise only reachable by
    /// running a real import.
    init(sourceText: String = "", phase: Phase = .idle) {
        _sourceText = State(initialValue: sourceText)
        _phase = State(initialValue: phase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header
            scrollingContent
            footer
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
        // The window is sized by `.windowResizability(.contentSize)`, so it is
        // only ever as tall as the ideal height this view reports. A greedy
        // `Spacer` under a 360pt floor made that height say "anything goes",
        // and the window settled on one that clipped whatever the result area
        // added off both edges; `fixedSize` reports the stacked height of the
        // real content instead, and the window follows it as the import moves
        // from idle to progress to result.
        .fixedSize(horizontal: false, vertical: true)
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
                Text("粘贴订阅链接、节点链接或本地文件，自动识别格式")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondaryLabel)
            }
        }
    }

    // MARK: - Content

    /// The source field plus the result area, which take exactly their own
    /// height until that passes `contentMaxHeight` — past which they scroll.
    /// Anything that can grow without bound (a pasted node list, a download
    /// error quoting the system's message, a long list of skipped nodes)
    /// therefore shortens the scrollable area rather than pushing the footer
    /// buttons out of the window.
    private var scrollingContent: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                inputCard
                resultArea
            }
        }
        .frame(maxHeight: Self.contentMaxHeight)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The tallest the content area grows before it scrolls: comfortably past
    /// the tallest result the flow produces today (a summary plus a handful of
    /// skipped nodes) while keeping the whole window short enough to fit a
    /// laptop screen. Matches the quick-add window's cap.
    private static let contentMaxHeight: CGFloat = 420

    // MARK: - Input

    private var inputCard: some View {
        Card(material: .regularMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader("来源", symbolName: "link")
                TextField(
                    "",
                    text: $sourceText,
                    prompt: Text("https://example.com/sub  ·  /路径/clash.yaml  ·  vmess://…"),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.mono)
                .lineLimit(3...8)
                .disabled(isImporting)
                Text("支持 Clash 订阅、V2Ray（Base64）订阅、本地文件，以及粘贴 ss / vmess / vless / trojan / hysteria2 / tuic 节点链接（可多行）。链接会作为手动节点导入。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Text("正在下载并解析…")
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
        case .finished(let summary, let warnings):
            ResultCard(summary: summary, warnings: warnings)
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
                let outcome = try await appState.importFromInput(trimmedSource)
                phase = .finished(summary: outcome.summary, warnings: outcome.warnings)
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
/// list of skipped-node warnings rendered icon-first.
private struct ResultCard: View {
    let summary: String
    let warnings: [String]

    var body: some View {
        Card(material: .thinMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label {
                    Text(summary)
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(Theme.Color.label)
                        .fixedSize(horizontal: false, vertical: true)
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
                    // No scroller of its own: the window's content area is
                    // already one, and a second along the same axis would trap
                    // the wheel in a 140pt box inside a scrolling window.
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            WarningRow(text: warning)
                        }
                    }
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
