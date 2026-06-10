import LinkoKit
import SwiftUI

/// The 日志 (Logs) surface: a live, level-colored stream of core log lines with
/// a severity filter (which re-subscribes the `/logs` socket at the new level),
/// an autoscroll toggle that follows the tail, and a clear-buffer action.
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.logs.enumerated()), id: \.offset) { index, entry in
                        LogRow(entry: entry)
                            .id(index)
                        Divider()
                            .opacity(0.4)
                    }
                    // Tail anchor for autoscroll.
                    Color.clear
                        .frame(height: 1)
                        .id(tailAnchor)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
            }
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
        .padding(.vertical, Theme.Spacing.xxs + 1)
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
