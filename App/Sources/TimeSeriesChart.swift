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
    /// Seconds the time axis covers, fixed from the first sample: the line enters at the right edge
    /// and scrolls left. Left to the data, the axis re-fits each time the line reaches the left edge,
    /// and the whole chart jumps.
    let window: Double
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
    /// Shown instead of an empty grid before the first samples land. Defaults to naming the metric
    /// and how soon it arrives; pass a specific message when the metric never will (no GPU fitted).
    var emptyMessage: String?

    var body: some View {
        let plotted = Self.fitted(series, interval: interval)
        // Each part is its own builder: as one `Chart { }` expression it is too much for CI's type checker.
        return Chart {
            seriesMarks(plotted.series, interval: plotted.interval)
            boundaryMarks(stacked ? Self.boundaries(plotted.series) : [], interval: plotted.interval)
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.tint))
        .chartXScale(domain: -window...0)
        .chartYScale(domain: 0...yTop)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: Array(stride(from: -window, through: 0, by: window / 5))) { value in
                AxisGridLine()
                // "now" sits at the plot's right edge: anchored the usual way it has no room and is dropped.
                AxisValueLabel(anchor: value.as(Double.self) == 0 ? .topTrailing : .topLeading) {
                    if let v = value.as(Double.self) { Text(Self.ago(v)) }
                }
            }
        }
        .chartLegend(showsLegend && series.count > 1 ? .visible : .hidden)
        .chartBackground { proxy in
            GeometryReader { geometry in
                Color.clear.preference(key: ChartPlotFrameKey.self, value: proxy.plotFrame.map { geometry[$0] })
            }
        }
        // A line needs two points; until then the grid would sit there empty saying nothing.
        .overlay { if isEmpty { emptyState } }
        // Swift Charts makes every mark its own element: a per-core chart is thousands of them,
        // which is unusable with VoiceOver. Collapse to one element that states the latest values.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? series.map(\.name).joined(separator: ", "))
        .accessibilityValue(summary)
    }

    @ChartContentBuilder
    private func seriesMarks(_ plotted: [Series], interval: Double) -> some ChartContent {
        ForEach(plotted) { s in
            ForEach(Array(s.values.enumerated()), id: \.offset) { index, value in
                if !value.isNaN {
                    let x = -Double(s.values.count - 1 - index) * interval
                    if stacked {
                        AreaMark(x: .value("Seconds ago", x), y: .value(s.name, value))
                            .interpolationMethod(ChartCurve.line)
                            .foregroundStyle(by: .value("Series", s.name))
                    } else {
                        if series.count == 1 {
                            AreaMark(x: .value("Seconds ago", x), y: .value(s.name, value))
                                .interpolationMethod(ChartCurve.line)
                                .foregroundStyle(LinearGradient(colors: [s.tint.opacity(0.3), s.tint.opacity(0.02)],
                                                                startPoint: .top, endPoint: .bottom))
                        }
                        LineMark(x: .value("Seconds ago", x), y: .value(s.name, value),
                                 series: .value("Series", s.name))
                            .interpolationMethod(ChartCurve.line)
                            .foregroundStyle(by: .value("Series", s.name))
                            .lineStyle(StrokeStyle(lineWidth: emphasis(s.name)))
                    }
                }
            }
        }
    }

    /// Shades of one hue cannot reach 3:1 against each other, so each band edge is drawn in
    /// the surface color: the boundary is identifiable even where two fills sit close.
    @ChartContentBuilder
    private func boundaryMarks(_ lines: [[Double]], interval: Double) -> some ChartContent {
        ForEach(Array(lines.enumerated()), id: \.offset) { band, line in
            ForEach(Array(line.enumerated()), id: \.offset) { index, value in
                if !value.isNaN {
                    let x = -Double(line.count - 1 - index) * interval
                    LineMark(x: .value("Seconds ago", x), y: .value("Boundary", value),
                             series: .value("Series", "boundary-\(band)"))
                        // The same curve as the bands, so each edge sits on the band it outlines.
                        .interpolationMethod(ChartCurve.line)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
        }
    }

    private var isEmpty: Bool {
        series.allSatisfy { $0.values.filter { !$0.isNaN }.count < 2 }
    }

    /// Quiet and self-resolving: the axes stay visible behind it, so the chart reads as filling in
    /// rather than broken. Nothing to click — at a one-second cadence it resolves itself.
    private var emptyState: some View {
        Text(emptyMessage ?? "\(accessibilityTitle ?? "Data") appears within a few seconds.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }

    /// "CPU 12%, 5 minutes" — latest value per series, then the span the chart covers.
    private var summary: String {
        let latest = series.compactMap { s -> String? in
            guard let value = s.values.last(where: { !$0.isNaN }) else { return nil }
            return "\(s.name) \(format(value))"
        }
        let span = Self.ago(-Double(series.map(\.values.count).max() ?? 0) * interval)
        guard !latest.isEmpty else { return emptyMessage ?? "No data yet" }
        return latest.joined(separator: ", ") + ", over \(span)"
    }

    private var yTop: Double {
        if let maximum { return maximum }
        let peak = series.flatMap(\.values).filter { !$0.isNaN }.max() ?? 1
        return Self.niceCeiling(peak)
    }

    /// The next 1, 2 or 5 × 10ⁿ at or above `peak`, never below 1. Fitting the axis to the peak
    /// itself rescales the chart on every new high; a stepped top moves only when a step is crossed.
    static func niceCeiling(_ peak: Double) -> Double {
        guard peak.isFinite, peak > 1 else { return 1 }
        let magnitude = pow(10, floor(log10(peak)))
        for step in [1.0, 2, 5, 10] where peak <= step * magnitude * (1 + 1e-9) {
            return step * magnitude
        }
        return 10 * magnitude
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

/// Where a chart's plot area sits inside the chart view, so a neighbour (the per-core heatmap)
/// can line its columns up with the chart's time axis.
struct ChartPlotFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
