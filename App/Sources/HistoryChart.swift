import SwiftUI
import Charts
import PulseCore
import PulseEngine
import PulseStore

/// Chart range: "Live" is the in-memory last few minutes; the rest read stored history (PRD §13).
enum ChartRange: TimeInterval, CaseIterable, Identifiable {
    case live = 0, hour = 3_600, sixHours = 21_600, day = 86_400, week = 604_800, month = 2_592_000

    var id: Self { self }
    var label: String {
        switch self {
        case .live: "Live"
        case .hour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        case .week: "7 d"
        case .month: "30 d"
        }
    }
}

struct ChartRangePicker: View {
    @Binding var range: ChartRange
    var body: some View {
        Picker("Range", selection: $range) {
            ForEach(ChartRange.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Stored history as avg lines with a min–max band; gaps where no data was recorded.
struct HistoryChart: View {
    struct Line: Hashable {
        let kind: MetricKind
        let name: String
    }

    let history: HistoryStore?
    let lines: [Line]
    let range: ChartRange
    var maximum: Double?
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    @State private var loaded: [Line: HistorySeries] = [:]
    @State private var error: String?

    var body: some View {
        Group {
            if history == nil {
                placeholder("History unavailable")
            } else if let error {
                placeholder(error)
            } else if loaded.values.allSatisfy({ $0.points.isEmpty }) {
                placeholder(loaded.isEmpty ? "Loading…" : "No data recorded in this range yet")
            } else {
                chart
            }
        }
        .task(id: range) {
            // Reload on range change and every 30 s (the history write interval) while visible.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(lines, id: \.self) { line in
                let series = loaded[line] ?? HistorySeries(points: [], stepSeconds: 1)
                ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
                    ForEach(segment, id: \.time) { point in
                        if series.stepSeconds > 1 {
                            AreaMark(x: .value("Time", point.time),
                                     yStart: .value("Min", point.min), yEnd: .value("Max", point.max),
                                     series: .value("Band", "\(line.name)-band-\(index)"))
                                .foregroundStyle(by: .value("Series", line.name))
                                .opacity(0.18)
                        }
                        LineMark(x: .value("Time", point.time), y: .value(line.name, point.avg),
                                 series: .value("Segment", "\(line.name)-\(index)"))
                            .foregroundStyle(by: .value("Series", line.name))
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                }
            }
        }
        .chartXScale(domain: Date().addingTimeInterval(-range.rawValue)...Date())
        .chartYScale(domain: 0...yTop)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)) } }
            }
        }
        .chartLegend(lines.count > 1 ? .visible : .hidden)
    }

    private var yTop: Double {
        if let maximum { return maximum }
        let peak = loaded.values.flatMap { $0.points.map(\.max) }.max() ?? 1
        return max(peak * 1.1, 1)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard let history, range != .live else { return }
        let from = Date().addingTimeInterval(-range.rawValue), to = Date(), lines = self.lines
        do {
            loaded = try await Task.detached {
                var result: [Line: HistorySeries] = [:]
                for line in lines { result[line] = try history.chartSeries(line.kind, from: from, to: to) }
                return result
            }.value
            error = nil
        } catch {
            self.error = "Could not read history: \(error.localizedDescription)"
        }
    }
}
