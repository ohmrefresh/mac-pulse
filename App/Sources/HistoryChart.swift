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

    /// The named option sets. A surface picks one of these rather than writing its own array, so
    /// "1 h" means the same span and sits in the same place on every page.
    ///
    /// `stored` drops Live for surfaces that only read recorded history; `sensors` also drops 30 d,
    /// because temperature is not kept that long.
    static let stored: [ChartRange] = [.hour, .sixHours, .day, .week, .month]
    static let sensors: [ChartRange] = [.hour, .sixHours, .day, .week]

    /// "Last 24 hours" — the span a stored-history page covers, in words.
    var spanName: String {
        switch self {
        case .live: "Live"
        case .hour: "Last hour"
        case .sixHours: "Last 6 hours"
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }
}

struct ChartRangePicker: View {
    @Binding var range: ChartRange
    var options: [ChartRange] = ChartRange.allCases
    /// When set, the live option is labelled by the span it covers ("5m") instead of "Live".
    var liveWindow: TimeInterval?
    var body: some View {
        Picker("Range", selection: $range) {
            ForEach(options) { option in
                Text(option == .live ? liveWindow.map(Self.span) ?? option.label : option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// "5m", "10m", or seconds below a minute.
    private static func span(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? "\(Int((seconds / 60).rounded()))m" : "\(Int(seconds))s"
    }
}

/// Stored history as avg lines with a min–max band; gaps where no data was recorded.
struct HistoryChart: View {
    struct Line {
        let kind: MetricKind
        let name: String
        var tint: Color = .accentColor
    }

    let history: HistoryStore?
    let lines: [Line]
    let range: ChartRange
    var maximum: Double?
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    /// Hovering shows a rule with every line's value at that time.
    var showsHoverDetails = false
    /// What the chart is of, for VoiceOver. The latest stored value per line is announced with it.
    var accessibilityTitle: String?
    /// Draws the second line (and its band) negated below a 0 baseline on a symmetric axis.
    var mirrored = false
    /// Applied to plotted values; hover details, labels and VoiceOver keep the real values.
    var scale: ChartScale = .linear
    /// Off when the page draws its own legend (e.g. with current values).
    var showsLegend = true
    /// Gridline positions in plotted values; nil lets Charts choose (temperatures pass round values
    /// in the display unit, from `TemperatureUnit.axisTicks`).
    var yTicks: [Double]?

    @State private var loaded: [MetricKind: HistorySeries] = [:]
    @State private var error: String?
    @State private var hoverDate: Date?

    var body: some View {
        Group {
            if history == nil {
                placeholder("History unavailable — Mac Pulse could not open its database.")
            } else if let error {
                placeholder("History could not be read. \(error)")
            } else if loaded.values.allSatisfy({ $0.points.isEmpty }) {
                // A fresh install has nothing stored yet; say so rather than implying a gap.
                placeholder(loaded.isEmpty ? "Loading…" : "Nothing recorded in the last \(range.label) yet. History builds while Mac Pulse runs.")
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

    // The body is split into builders so CI's Swift 6.2 can type-check it in time (see TimeSeriesChart).
    private var chart: some View {
        Chart {
            ForEach(lines, id: \.kind) { line in
                lineMarks(line)
            }
            if let hoverDate {
                hoverRule(at: hoverDate)
            }
        }
        .chartOverlay { proxy in
            if showsHoverDetails {
                hoverOverlay(proxy)
            }
        }
        .chartForegroundStyleScale(domain: lines.map(\.name), range: lines.map(\.tint))
        .chartXScale(domain: Date().addingTimeInterval(-range.rawValue)...Date())
        .chartYScale(domain: (mirrored ? -yTop : 0)...yTop)
        .chartYAxis { yAxis }
        .chartLegend(showsLegend && lines.count > 1 ? .visible : .hidden)
        // One element for the whole chart; see TimeSeriesChart for why.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? lines.map(\.name).joined(separator: ", "))
        .accessibilityValue(summary)
    }

    @ChartContentBuilder
    private func lineMarks(_ line: Line) -> some ChartContent {
        let series = loaded[line.kind] ?? HistorySeries(points: [], stepSeconds: 1)
        let sign: Double = mirrored && lines.count > 1 && line.kind == lines[1].kind ? -1 : 1
        ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
            ForEach(segment, id: \.time) { point in
                if series.stepSeconds > 1 {
                    bandMark(point, line: line, sign: sign, index: index)
                }
                averageMark(point, line: line, sign: sign, index: index)
            }
        }
    }

    private func bandMark(_ point: HistoryPoint, line: Line, sign: Double, index: Int) -> some ChartContent {
        AreaMark(x: .value("Time", point.time),
                 yStart: .value("Min", scale.plot(sign * point.min)),
                 yEnd: .value("Max", scale.plot(sign * point.max)),
                 series: .value("Band", "\(line.name)-band-\(index)"))
            .interpolationMethod(ChartCurve.line)
            .foregroundStyle(by: .value("Series", line.name))
            .opacity(0.18)
    }

    private func averageMark(_ point: HistoryPoint, line: Line, sign: Double, index: Int) -> some ChartContent {
        LineMark(x: .value("Time", point.time), y: .value(line.name, scale.plot(sign * point.avg)),
                 series: .value("Segment", "\(line.name)-\(index)"))
            .interpolationMethod(ChartCurve.line)
            .foregroundStyle(by: .value("Series", line.name))
            .lineStyle(StrokeStyle(lineWidth: 1.4))
    }

    private func hoverRule(at date: Date) -> some ChartContent {
        RuleMark(x: .value("Time", date))
            .foregroundStyle(.secondary.opacity(0.6))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, alignment: .center, spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                hoverDetails(at: date)
            }
    }

    private func hoverOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let frame = proxy.plotFrame else { return }
                        hoverDate = proxy.value(atX: location.x - geo[frame].origin.x, as: Date.self)
                    case .ended:
                        hoverDate = nil
                    }
                }
        }
    }

    @AxisContentBuilder
    private var yAxis: some AxisContent {
        if scale == .signedLog {
            AxisMarks(values: scale.ticks(maxMagnitude: scale.value(yTop), mirrored: mirrored)) { value in
                axisMark(value)
            }
        } else if let yTicks {
            AxisMarks(values: yTicks) { value in
                axisMark(value)
            }
        } else {
            AxisMarks { value in
                axisMark(value)
            }
        }
    }

    @AxisMarkBuilder
    private func axisMark(_ value: AxisValue) -> some AxisMark {
        AxisGridLine()
        AxisValueLabel { if let v = value.as(Double.self) { Text(axisLabel(v)) } }
    }

    /// "CPU 12%, last 1 h" — the newest stored value per line over the selected range.
    private var summary: String {
        let latest = lines.compactMap { line -> String? in
            guard let point = loaded[line.kind]?.points.last else { return nil }
            return "\(line.name) \(format(point.avg))"
        }
        guard !latest.isEmpty else { return "No data recorded in this range" }
        return latest.joined(separator: ", ") + ", last \(range.label)"
    }

    /// Nearest recorded point of each line to `date` (within 2 buckets, or 90 s for sparse series like sensors).
    private func hoverDetails(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date, format: range.rawValue > 86_400 ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute())
                .font(.caption.weight(.semibold))
            ForEach(lines, id: \.kind) { line in
                if let series = loaded[line.kind],
                   let point = series.points.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }),
                   abs(point.time.timeIntervalSince(date)) <= max(Double(series.stepSeconds) * 2, 90) {
                    HStack(spacing: 6) {
                        Circle().fill(line.tint).frame(width: 7, height: 7)
                        Text(line.name)
                        Spacer(minLength: 12)
                        Text(format(point.avg)).monospacedDigit().fontWeight(.medium)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 130)
        // Opaque surface plus a hairline, like every other panel. Glass over a moving chart both
        // breaks the flat rule and lets the plot show through the figures it is meant to explain.
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    /// Plotted top of the y-axis; a mirrored chart spans the same distance below 0.
    private var yTop: Double {
        if let maximum { return scale.plot(maximum) }
        let peak = loaded.values.flatMap { $0.points.map(\.max) }.max() ?? 1
        return scale == .linear ? max(peak * 1.1, 1) : scale.top(maxMagnitude: peak)
    }

    /// Labels read as magnitudes: the mirrored line's "-10 MB/s" is still 10 MB/s.
    private func axisLabel(_ plotted: Double) -> String {
        format(abs(scale.value(plotted)))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard let history, range != .live else { return }
        let from = Date().addingTimeInterval(-range.rawValue), to = Date(), lines = self.lines
        do {
            loaded = try await Task.detached {
                try Self.loadSeries(history: history, lines: lines, from: from, to: to)
            }.value
            error = nil
        } catch {
            self.error = "Could not read history: \(error.localizedDescription)"
        }
    }

    /// Keyed by metric, not `Line`: a `Line.tint` from `MetricStyle.shade` is a new dynamic
    /// color on every render and never equal, so a `Line` key misses after the next re-render.
    nonisolated static func loadSeries(history: HistoryStore, lines: [Line], from: Date, to: Date) throws -> [MetricKind: HistorySeries] {
        var result: [MetricKind: HistorySeries] = [:]
        for line in lines { result[line.kind] = try history.chartSeries(line.kind, from: from, to: to) }
        return result
    }
}
