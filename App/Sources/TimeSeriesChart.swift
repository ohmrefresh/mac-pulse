import SwiftUI
import Charts

/// Equally spaced samples plotted against "seconds ago". NaN values render as gaps.
struct TimeSeriesChart: View {
    struct Series: Identifiable {
        let name: String
        let values: [Double]
        var tint: Color = .accentColor
        var id: String { name }
    }

    let series: [Series]
    /// Seconds between samples.
    let interval: Double
    /// Fixed top of the y-axis (e.g. 100 for percentages); nil scales to the data.
    var maximum: Double?
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    /// Draws the series as bands adding up to a total (memory split) instead of independent lines.
    var stacked = false
    /// Legend is noise once a chart draws one line per core; the caption explains it instead.
    var showsLegend = true
    /// Line width per series name, so one line (the CPU total) can be emphasised over the rest.
    var emphasis: (String) -> CGFloat = { _ in 1.4 }

    var body: some View {
        let plotted = Self.fitted(series, interval: interval)
        return Chart {
            ForEach(plotted.series) { s in
                ForEach(Array(s.values.enumerated()), id: \.offset) { index, value in
                    if !value.isNaN {
                        let x = -Double(s.values.count - 1 - index) * plotted.interval
                        if stacked {
                            AreaMark(x: .value("Seconds ago", x), y: .value(s.name, value))
                                .foregroundStyle(by: .value("Series", s.name))
                        } else {
                            if series.count == 1 {
                                AreaMark(x: .value("Seconds ago", x), y: .value(s.name, value))
                                    .foregroundStyle(LinearGradient(colors: [s.tint.opacity(0.3), s.tint.opacity(0.02)],
                                                                    startPoint: .top, endPoint: .bottom))
                            }
                            LineMark(x: .value("Seconds ago", x), y: .value(s.name, value),
                                     series: .value("Series", s.name))
                                .foregroundStyle(by: .value("Series", s.name))
                                .lineStyle(StrokeStyle(lineWidth: emphasis(s.name)))
                        }
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.tint))
        .chartYScale(domain: 0...yTop)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)) } }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(Self.ago(v)) } }
            }
        }
        .chartLegend(showsLegend && series.count > 1 ? .visible : .hidden)
    }

    private var yTop: Double {
        if let maximum { return maximum }
        let peak = series.flatMap(\.values).filter { !$0.isNaN }.max() ?? 1
        return max(peak * 1.15, 1)
    }

    /// A per-core chart is a dozen series of 300 samples; drawing every point would blow the 250 ms
    /// UI budget. Buckets are reduced by max so spikes survive, and the x spacing grows to match.
    static let pointBudget = 1_200

    static func fitted(_ series: [Series], interval: Double) -> (series: [Series], interval: Double) {
        let longest = series.map(\.values.count).max() ?? 0
        let marks = longest * max(series.count, 1)
        guard marks > pointBudget, longest > 1 else { return (series, interval) }
        let factor = Int((Double(marks) / Double(pointBudget)).rounded(.up))
        return (series.map { Series(name: $0.name, values: downsampled($0.values, by: factor), tint: $0.tint) },
                interval * Double(factor))
    }

    /// Peak of each bucket, oldest first. All-NaN buckets stay NaN so gaps remain gaps.
    static func downsampled(_ values: [Double], by factor: Int) -> [Double] {
        guard factor > 1 else { return values }
        return stride(from: 0, to: values.count, by: factor).map { start in
            let bucket = values[start..<min(start + factor, values.count)].filter { !$0.isNaN }
            return bucket.max() ?? .nan
        }
    }

    private static func ago(_ seconds: Double) -> String {
        let s = Int(-seconds)
        if s == 0 { return "now" }
        return s >= 60 ? "\(s / 60)m" : "\(s)s"
    }
}
