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

    var body: some View {
        Chart {
            ForEach(series) { s in
                ForEach(Array(s.values.enumerated()), id: \.offset) { index, value in
                    if !value.isNaN {
                        if series.count == 1 {
                            AreaMark(x: .value("Seconds ago", -Double(s.values.count - 1 - index) * interval),
                                     y: .value(s.name, value))
                                .foregroundStyle(LinearGradient(colors: [s.tint.opacity(0.3), s.tint.opacity(0.02)],
                                                                startPoint: .top, endPoint: .bottom))
                        }
                        LineMark(
                            x: .value("Seconds ago", -Double(s.values.count - 1 - index) * interval),
                            y: .value(s.name, value),
                            series: .value("Series", s.name)
                        )
                        .foregroundStyle(by: .value("Series", s.name))
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
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
        .chartLegend(series.count > 1 ? .visible : .hidden)
    }

    private var yTop: Double {
        if let maximum { return maximum }
        let peak = series.flatMap(\.values).filter { !$0.isNaN }.max() ?? 1
        return max(peak * 1.15, 1)
    }

    private static func ago(_ seconds: Double) -> String {
        let s = Int(-seconds)
        if s == 0 { return "now" }
        return s >= 60 ? "\(s / 60)m" : "\(s)s"
    }
}
