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
    /// What the chart is of, for VoiceOver ("CPU usage"). The latest value per series is announced with it.
    var accessibilityTitle: String?

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
            // Shades of one hue cannot reach 3:1 against each other, so each band edge is drawn in
            // the surface color: the boundary is identifiable even where two fills sit close.
            ForEach(Array((stacked ? Self.boundaries(plotted.series) : []).enumerated()), id: \.offset) { band, line in
                ForEach(Array(line.enumerated()), id: \.offset) { index, value in
                    if !value.isNaN {
                        LineMark(x: .value("Seconds ago", -Double(line.count - 1 - index) * plotted.interval),
                                 y: .value("Boundary", value),
                                 series: .value("Series", "boundary-\(band)"))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .lineStyle(StrokeStyle(lineWidth: 1))
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
        // Swift Charts makes every mark its own element: a per-core chart is thousands of them,
        // which is unusable with VoiceOver. Collapse to one element that states the latest values.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? series.map(\.name).joined(separator: ", "))
        .accessibilityValue(summary)
    }

    /// "CPU 12%, 5 minutes" — latest value per series, then the span the chart covers.
    private var summary: String {
        let latest = series.compactMap { s -> String? in
            guard let value = s.values.last(where: { !$0.isNaN }) else { return nil }
            return "\(s.name) \(format(value))"
        }
        let span = Self.ago(-Double(series.map(\.values.count).max() ?? 0) * interval)
        guard !latest.isEmpty else { return "No data yet" }
        return latest.joined(separator: ", ") + ", over \(span)"
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

    /// Running totals at each internal band edge of a stacked chart, oldest first. The outermost
    /// edge is left out: it borders the plot area, which already reads as an edge.
    static func boundaries(_ series: [Series]) -> [[Double]] {
        guard series.count > 1 else { return [] }
        let length = series.map(\.values.count).max() ?? 0
        guard length > 0 else { return [] }
        var running = [Double](repeating: 0, count: length)
        return series.dropLast().map { s in
            let offset = length - s.values.count
            for index in 0..<length where index >= offset {
                let value = s.values[index - offset]
                running[index] += value.isNaN ? 0 : value
            }
            return running
        }
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
