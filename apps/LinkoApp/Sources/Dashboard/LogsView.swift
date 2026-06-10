import AppKit
import LinkoKit
import SwiftUI
import UniformTypeIdentifiers

/// The 日志 (Logs) surface: a live, level-colored stream of core log lines with
/// a severity filter (which re-subscribes the `/logs` socket at the new level),
/// an autoscroll toggle that follows the tail, an export-to-file action, and a
/// clear-buffer action.
///
/// Rendered as a native `List` so row separators come from the platform (no
/// hand-rolled `Divider`s) and the pane background matches every other
/// dashboard surface (no boxes-on-grey).
struct LogsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var viewModel: DashboardViewModel

    @State private var autoScroll = true

    /// Sentinel id parked at the very bottom of the list; scrolling to it keeps
    /// the newest line in view while autoscroll is on.
    private let tailAnchor = "logs-tail-anchor"

    var body: some View {
        Group {
            if !appState.isCoreRunning {
                DashboardEmptyState(
                    symbolName: "text.alignleft",
                    title: "核心未运行",
                    message: "开启系统代理后，这里会实时显示核心日志。"
                )
            } else {
                logList
            }
        }
        .toolbar { toolbar }
    }

    // MARK: - List

    private var logList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(viewModel.logs.enumerated()), id: \.offset) { index, entry in
                    LogRow(entry: entry)
                        .id(index)
                        .listRowInsets(EdgeInsets(
                            top: Theme.Spacing.xxs + 1,
                            leading: Theme.Spacing.md,
                            bottom: Theme.Spacing.xxs + 1,
                            trailing: Theme.Spacing.md
                        ))
                        .listRowSeparator(.visible)
                }
                // Tail anchor for autoscroll: a zero-height, separator-less row.
                Color.clear
                    .frame(height: 1)
                    .id(tailAnchor)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if viewModel.logs.isEmpty {
                    DashboardEmptyState(
                        symbolName: "ellipsis.bubble",
                        title: "暂无日志",
                        message: "等待核心输出日志，或切换上方的日志级别。"
                    )
                }
            }
            .onChange(of: viewModel.logs.count) { _, _ in
                guard autoScroll else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(tailAnchor, anchor: .bottom)
                }
            }
            .onChange(of: autoScroll) { _, isOn in
                guard isOn else { return }
                proxy.scrollTo(tailAnchor, anchor: .bottom)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("级别", selection: $viewModel.logLevel) {
                ForEach(ClashLogLevel.allCases, id: \.self) { level in
                    Text(levelTitle(level)).tag(level)
                }
            }
            .pickerStyle(.menu)
            .help("日志级别")
        }
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $autoScroll) {
                Label("自动滚动", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("自动滚动到最新")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: exportLogs) {
                Label("导出日志", systemImage: "square.and.arrow.up")
            }
            .help("导出日志到文件")
            .disabled(viewModel.logs.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.clearLogs()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .help("清空日志")
            .disabled(viewModel.logs.isEmpty)
        }
    }

    // MARK: - Export

    /// Serializes the visible log buffer to a plain-text file via a save panel.
    /// Each line is `LEVEL\tpayload`, matching what's on screen.
    private func exportLogs() {
        let snapshot = viewModel.logs
        guard !snapshot.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "导出日志"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.defaultExportName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = snapshot
            .map { entry in
                let level = entry.type.isEmpty ? "LOG" : entry.type.uppercased()
                return "\(level)\t\(entry.payload)"
            }
            .joined(separator: "\n")

        do {
            try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appState.lastErrorMessage = "导出日志失败：\(error.localizedDescription)"
        }
    }

    /// A timestamped default filename, e.g. `linko-logs-20260610-153045.txt`.
    private static func defaultExportName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "linko-logs-\(formatter.string(from: Date())).txt"
    }

    // MARK: - Helpers

    private func levelTitle(_ level: ClashLogLevel) -> String {
        switch level {
        case .debug: return "调试"
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }
}

// =============================================================================
// MARK: - LogRow
// =============================================================================

/// One monospaced log line: a colored level tag followed by the payload, tinted
/// to severity. Designed to be dense and copy-friendly.
private struct LogRow: View {
    let entry: ClashLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text(tagText)
                .font(Theme.Font.caption2.weight(.bold))
                .foregroundStyle(levelColor)
                .frame(width: 56, alignment: .leading)
            Text(entry.payload)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.label)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var tagText: String {
        entry.type.isEmpty ? "LOG" : entry.type.uppercased()
    }

    /// Maps the core's severity label to a Theme status color.
    private var levelColor: Color {
        switch entry.type.lowercased() {
        case "error": return Theme.Color.error
        case "warning", "warn": return Theme.Color.warning
        case "info": return Theme.Color.info
        case "debug": return Theme.Color.tertiaryLabel
        default: return Theme.Color.secondaryLabel
        }
    }
}
