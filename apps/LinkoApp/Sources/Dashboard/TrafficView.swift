import Charts
import LinkoKit
import SwiftUI

/// The 流量 (Traffic) surface: a live Swift Charts area + line plot of the
/// per-second up/down history with a current-rate headline and peak markers.
/// Scales smoothly off the view model's rolling 60-sample ring buffer.
struct TrafficView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var viewModel: DashboardViewModel

    /// Direction series, used to fold both up and down into one plottable set
    /// with a shared color legend.
    private enum Direction: String, Plottable {
        case download = "下载"
        case upload = "上传"

        var color: Color {
            switch self {
            case .download: return Theme.Color.download
            case .upload: return Theme.Color.upload
            }
        }
    }

    var body: some View {
        Group {
            if !appState.isCoreRunning {
                DashboardEmptyState(
                    symbolName: "chart.xyaxis.line",
                    title: "核心未运行",
                    message: "开启系统代理后，这里会实时绘制上下行速率曲线。"
                )
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            headline
            Card {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    SectionHeader("速率曲线", symbolName: "waveform.path.ecg") {
                        legend
                    }
                    chart
                        .frame(minHeight: 260)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Headline

    private var headline: some View {
        HStack(spacing: Theme.Spacing.xxl) {
            MetricView(
                value: ByteFormatter.rateString(bytesPerSecond: viewModel.currentDownRate),
                caption: "当前下载  ·  峰值 \(ByteFormatter.rateString(bytesPerSecond: viewModel.peakDownRate))",
                symbolName: "arrow.down",
                tint: Theme.Color.download
            )
            MetricView(
                value: ByteFormatter.rateString(bytesPerSecond: viewModel.currentUpRate),
                caption: "当前上传  ·  峰值 \(ByteFormatter.rateString(bytesPerSecond: viewModel.peakUpRate))",
                symbolName: "arrow.up",
                tint: Theme.Color.upload
            )
            Spacer(minLength: 0)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: Theme.Spacing.md) {
            legendDot(.download)
            legendDot(.upload)
        }
    }

    private func legendDot(_ direction: Direction) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Circle()
                .fill(direction.color)
                .frame(width: 8, height: 8)
            Text(direction.rawValue)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(viewModel.trafficHistory) { sample in
                // Download — filled area + line.
                AreaMark(
                    x: .value("时间", sample.index),
                    y: .value("速率", sample.down),
                    series: .value("方向", Direction.download.rawValue)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [Direction.download.color.opacity(0.28), Direction.download.color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("时间", sample.index),
                    y: .value("速率", sample.down),
                    series: .value("方向", Direction.download.rawValue)
                )
                .foregroundStyle(Direction.download.color)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                .interpolationMethod(.monotone)

                // Upload — line only, so the two series stay legible overlaid.
                LineMark(
                    x: .value("时间", sample.index),
                    y: .value("速率", sample.up),
                    series: .value("方向", Direction.upload.rawValue)
                )
                .foregroundStyle(Direction.upload.color)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...yAxisUpperBound)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Theme.Color.separator.opacity(0.5))
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(ByteFormatter.rateString(bytesPerSecond: bytes))
                            .font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Color.tertiaryLabel)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: viewModel.trafficHistory)
        .overlay {
            if viewModel.trafficHistory.isEmpty {
                Text("正在等待流量数据…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
            }
        }
    }

    /// Headroom above the observed peak so the curve never touches the top
    /// edge; floors at 1 KB/s so an idle connection still renders a flat axis.
    private var yAxisUpperBound: Int64 {
        let peak = max(viewModel.peakDownRate, viewModel.peakUpRate)
        let floored = max(peak, 1_024)
        return Int64(Double(floored) * 1.2)
    }
}
