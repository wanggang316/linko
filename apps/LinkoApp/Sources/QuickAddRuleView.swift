import AppKit
import SwiftUI

/// Shell window for「为当前网页添加规则」: renders the capture outcome —
/// progress, the page captured from the frontmost browser, or a categorized
/// failure with its guidance — plus a manual fallback input. The full rule
/// form (candidate scopes, rule type, target, save) belongs to the next
/// feature; nothing entered here is persisted yet.
struct QuickAddRuleView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Manual fallback input. Not wired to saving yet (the quick-add form
    /// feature owns persistence); reset whenever a fresh capture starts.
    @State private var manualInput = ""

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
        .onChange(of: appState.quickAddCapture) { _, newState in
            // A re-trigger resets the whole window to the new capture.
            if newState == .capturing { manualInput = "" }
        }
    }

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
            capturedCard(urlString: urlString)
        case .manual(let guidance):
            manualCard(guidance: guidance)
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

    /// The captured page, shown by host only in this shell stage (the full
    /// form will offer domain/URL scopes). The URL stays in memory — it is
    /// never logged.
    private func capturedCard(urlString: String) -> some View {
        Card(material: .thinMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label {
                    Text("已捕获当前网页")
                        .font(Theme.Font.bodyEmphasized)
                        .foregroundStyle(Theme.Color.label)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Color.active)
                }
                Text(Self.displayHost(from: urlString))
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Color.label)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    /// Manual-input mode: the failure guidance (when a capture preceded it),
    /// a System Settings shortcut for a TCC denial, and the fallback field.
    private func manualCard(guidance: QuickAddCapture.Guidance?) -> some View {
        Card(material: .thinMaterial) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if let guidance {
                    HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Color.info)
                        Text(guidance.message)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if guidance.offersAutomationSettings {
                        Button("打开系统设置 › 隐私与安全性 › 自动化") {
                            openAutomationSettings()
                        }
                        .buttonStyle(.link)
                        .font(Theme.Font.caption)
                    }
                    Divider().opacity(0.5)
                }
                SectionHeader("手动输入", symbolName: "square.and.pencil")
                TextField(
                    "",
                    text: $manualInput,
                    prompt: Text("example.com 或 https://example.com/page")
                )
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.mono)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Helpers

    /// The captured page reduced to its host for display; falls back to the
    /// raw string when it carries no parseable host (shown, never logged).
    private static func displayHost(from urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    private func openAutomationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
