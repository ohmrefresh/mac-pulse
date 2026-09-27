import SwiftUI
import Charts
import PulseCore
import PulseCollectors
import PulseEngine
import PulseStore

/// Sensors page (`docs/prd/sensor.png`): temperature cards, history chart, sensor table, fans and
/// thermal state. Temperatures are informational; only the Thermal State carries a Health Level.
struct SensorsView: View {
    let metrics: LiveMetrics
    let showThermalHistory: () -> Void
    @State private var range: ChartRange = .hour


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let s = metrics.sensors, !s.sensors.isEmpty {
                    cards(s)
                    HStack(alignment: .top, spacing: 16) {
                        temperatureOverview
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)
                        SensorTable(sensors: s.sensors, extremes: metrics.sensorExtremes)
                            .frame(minWidth: 330, maxWidth: 440)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    unavailableNote
                }
                HStack(alignment: .top, spacing: 16) {
                    FanStatus(fans: metrics.sensors?.fans, loaded: metrics.sensors != nil)
                    ThermalStateCard(history: metrics.history, range: range, showHistory: showThermalHistory)
                        .layoutPriority(1)
                }
                .fixedSize(horizontal: false, vertical: true)
                Text("Temperatures and fans use undocumented macOS interfaces and may be unavailable after a macOS update.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .onAppear(perform: metrics.sensorsAppeared)
        .onDisappear(perform: metrics.sensorsDisappeared)
    }

    // MARK: Header

    /// The same header every other page draws: title, subtitle, and the range picker in the
    /// trailing slot. The page-title glyph and the bordered banner this page used to own existed
    /// nowhere else in the app; thermal state now speaks through the standard Health badge.
    private var header: some View {
        PageHeader(title: "Sensors",
                   subtitle: "Real-time temperature and hardware sensors from your Mac.") {
            VStack(alignment: .trailing, spacing: 10) {
                thermalBadge
                ChartRangePicker(range: $range, options: ChartRange.sensors)
            }
        }
    }

    /// Thermal state as the app's one status component, with the machine's own word for the state.
    private var thermalBadge: some View {
        let state = metrics.thermal
        let level = state?.health ?? .unknown
        return HealthBadge(level: level,
                           label: state.map { "Thermal state \(Format.thermal($0))" } ?? "Thermal state unknown")
    }

    // MARK: Cards

    /// A tile per sensor this Mac actually reports. A machine without an SSD or battery probe gets
    /// three tiles or two, never a tile with a dash in it.
    private func cards(_ s: SensorsReading) -> some View {
        HStack(spacing: 16) {
            if let cpu = s.cpuCelsius {
                TemperatureCard(title: "CPU", caption: "hottest core", style: .cpu,
                                value: cpu, series: metrics.temperatureHistory)
            }
            if let hottest = s.hottest {
                TemperatureCard(title: "Hottest", caption: hottest.name, style: .temperature,
                                value: hottest.celsius, series: metrics.hottestTemperatureHistory)
            }
            if let ssd = s.ssdCelsius {
                TemperatureCard(title: "SSD", caption: nil, style: .ssdTemperature,
                                value: ssd, series: metrics.ssdTemperatureHistory)
            }
            if let battery = s.batteryCelsius {
                TemperatureCard(title: "Battery", caption: nil, style: .batteryTemperature,
                                value: battery, series: metrics.batteryTemperatureHistory)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Temperature Overview

    private var temperatureOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cpu").foregroundStyle(MetricStyle.temperature.tint).font(.title3)
                Text("Temperature Overview").font(.headline)
            }
            HistoryChart(history: metrics.history,
                         lines: [.init(kind: .hottestTemperatureC, name: "Hottest", tint: MetricStyle.temperature.tint),
                                 .init(kind: .cpuTemperatureC, name: "CPU", tint: MetricStyle.cpu.tint),
                                 .init(kind: .ssdTemperatureC, name: "SSD", tint: MetricStyle.ssdTemperature.tint),
                                 .init(kind: .batteryTemperatureC, name: "Battery", tint: MetricStyle.batteryTemperature.tint)],
                         range: range, maximum: 100, format: { "\(Int($0))°C" }, showsHoverDetails: true)
                .frame(minHeight: 280)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .cardBackground()
    }

    private var unavailableNote: some View {
        Group {
            if metrics.sensors == nil {
                ProgressView().controlSize(.small)
            } else {
                Label("Temperature sensors are not available on this Mac or macOS version.", systemImage: "thermometer.medium.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

// MARK: - Temperature card

/// Value, change over the last 15 minutes, and a sparkline of the in-memory series.
private struct TemperatureCard: View {
    let title: String
    let caption: String?
    let style: MetricStyle
    let value: Double
    let series: TimedSeries

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Plain tinted glyph, as on every other tile: the filled chip was a shape this page
            // invented and no other surface used.
            Image(systemName: style.symbol)
                .font(.title3)
                .foregroundStyle(style.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Text(Format.celsius(value)).font(.title.weight(.semibold)).monospacedDigit()
                change
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .fixedSize(horizontal: true, vertical: false)
            Sparkline(values: series.values, tint: style.tint, height: 44)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(padding: 14)
    }

    /// "↓ 2°C" over 15 min. Until the series spans 15 minutes there is no change to report, so the
    /// row is absent rather than showing a minus sign next to a dash.
    @ViewBuilder
    private var change: some View {
        if let delta = series.change(over: 900).map({ Int($0.rounded()) }) {
            changeRow(delta)
        }
    }

    private func changeRow(_ delta: Int) -> some View {
        HStack(spacing: 3) {
            // Direction carries it; status colour belongs to Health Level alone, and a 1 °C drift
            // painted orange is exactly the routine variation the alarmist rule warns about.
            Image(systemName: delta > 0 ? "arrow.up" : (delta < 0 ? "arrow.down" : "minus"))
            Text("\(abs(delta))°C")
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
        .help("Change over the last 15 minutes")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(delta == 0 ? "No change over the last 15 minutes"
                                       : "\(delta > 0 ? "Up" : "Down") \(abs(delta)) degrees over the last 15 minutes")
    }
}

// MARK: - Sensor table

private struct SensorTable: View {
    let sensors: [TemperatureSensor]
    let extremes: [String: ClosedRange<Double>]
    @State private var sort: Sort = .highest
    @State private var showAll = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Sort: String, CaseIterable { case highest = "Highest first", name = "Name" }

    private static let collapsedCount = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sensor").foregroundStyle(MetricStyle.cpu.tint).font(.title3)
                Text("Sensors (\(sensors.count))").font(.headline)
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Sensor").gridCellColumns(2)
                    Text("Current").gridColumnAlignment(.trailing)
                    Text("Min").gridColumnAlignment(.trailing)
                    Text("Max").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(visible) { sensor in
                    let range = extremes[sensor.name]
                    GridRow {
                        Image(systemName: Self.symbol(for: sensor.name))
                            .foregroundStyle(Self.tint(for: sensor.name)).frame(width: 18)
                        Text(sensor.name).lineLimit(1).truncationMode(.middle)
                        Text(Format.celsius(sensor.celsius)).fontWeight(.medium)
                        Text(range.map { Format.celsius($0.lowerBound) } ?? "").foregroundStyle(.secondary)
                        Text(range.map { Format.celsius($0.upperBound) } ?? "").foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
            }
            HStack {
                if sensors.count > Self.collapsedCount {
                    Button(showAll ? "Show fewer" : "View all \(sensors.count) sensors") {
                        // The one animation the app ships; Reduce Motion gets the same disclosure
                        // without the expansion.
                        withAnimation(reduceMotion ? nil : .snappy) { showAll.toggle() }
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Text("Min / Max since launch").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .cardBackground()
    }

    private var visible: [TemperatureSensor] {
        let sorted = sort == .highest
            ? sensors.sorted { $0.celsius > $1.celsius }
            : sensors.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return showAll ? sorted : Array(sorted.prefix(Self.collapsedCount))
    }

    private static func symbol(for name: String) -> String {
        if name.contains("tdie") { return MetricStyle.cpu.symbol }
        if name.hasPrefix("NAND") { return MetricStyle.ssdTemperature.symbol }
        if name.localizedCaseInsensitiveContains("gas gauge") || name.localizedCaseInsensitiveContains("battery") {
            return MetricStyle.batteryTemperature.symbol
        }
        return MetricStyle.temperature.symbol
    }

    private static func tint(for name: String) -> Color {
        if name.contains("tdie") { return MetricStyle.cpu.tint }
        if name.hasPrefix("NAND") { return MetricStyle.ssdTemperature.tint }
        if name.localizedCaseInsensitiveContains("gas gauge") || name.localizedCaseInsensitiveContains("battery") {
            return MetricStyle.batteryTemperature.tint
        }
        return MetricStyle.temperature.tint
    }
}

// MARK: - Fans

private struct FanStatus: View {
    let fans: [FanReading]?
    let loaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "fan").foregroundStyle(MetricStyle.cpu.tint).font(.title3)
                Text("Fan Status").font(.headline)
            }
            if let fans, !fans.isEmpty {
                ForEach(Array(fans.enumerated()), id: \.element.id) { index, fan in
                    if index > 0 { Divider() }
                    row(fan)
                }
            } else if loaded {
                InlineEmpty("This Mac has no fans, or they can't be read.")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }

    private func row(_ fan: FanReading) -> some View {
        let stopped = fan.rpm < 1
        let fraction = fan.maxRPM.flatMap { $0 > 0 ? min(fan.rpm / $0, 1) : nil }
        return HStack(spacing: 12) {
            Image(systemName: "fan").foregroundStyle(.secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fan \(fan.index + 1)").foregroundStyle(.secondary)
                Text("\(Int(fan.rpm.rounded())) RPM").font(.headline).monospacedDigit()
            }
            .fixedSize()
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                if stopped {
                    Text("Stopped").font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if let fraction {
                    HStack(spacing: 8) {
                        UsageBar(fraction: fraction, tint: MetricStyle.cpu.tint).frame(minWidth: 80, maxWidth: 200)
                        Text(Format.percent(fraction * 100)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
        // No inner fill: this row already sits inside the Fan Status card, and a card in a card is
        // the one nesting the system rules out. Rows separate by rhythm instead.
        .padding(.vertical, 6)
    }
}

// MARK: - Thermal state

/// macOS Thermal State over the page range: stepped line on Nominal…Critical bands.
private struct ThermalStateCard: View {
    let history: HistoryStore?
    let range: ChartRange
    let showHistory: () -> Void

    @State private var series: HistorySeries?
    @State private var error: String?

    /// Thermal bands read as marks on the card, so each has to clear 3:1 in both appearances —
    /// `.yellow` at its own lightness measures about 1.5:1 on a light surface.
    private static let levels: [(state: ThermalState, color: Color)] = [
        (.nominal, Color.green.readableInk(on: .card, minimum: 3)),
        (.fair, Color.yellow.readableInk(on: .card, minimum: 3)),
        (.serious, Color.orange.readableInk(on: .card, minimum: 3)),
        (.critical, Color.red.readableInk(on: .card, minimum: 3)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path").foregroundStyle(MetricStyle.temperature.tint).font(.title3)
                Text("Thermal State").font(.headline)
                Spacer()
                Button("View History", action: showHistory).controlSize(.small)
            }
            content.frame(height: 150)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
        .task(id: range) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder private var content: some View {
        if history == nil {
            placeholder("History unavailable")
        } else if let error {
            placeholder(error)
        } else if let series, !series.points.isEmpty {
            chart(series)
        } else {
            placeholder(series == nil ? "Reading history…" : "No data recorded in this range")
        }
    }

    private func chart(_ series: HistorySeries) -> some View {
        let from = Date().addingTimeInterval(-range.rawValue), to = Date()
        return Chart {
            ForEach(Self.levels, id: \.state) { level in
                RectangleMark(xStart: .value("From", from), xEnd: .value("To", to),
                              yStart: .value("Low", Double(level.state.rawValue) - 0.5),
                              yEnd: .value("High", Double(level.state.rawValue) + 0.5))
                    .foregroundStyle(level.color.opacity(0.12))
            }
            ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
                // One color per segment (a line can't change color mid-way): its worst state.
                let worst = segment.map(\.max).max() ?? 0
                ForEach(segment, id: \.time) { point in
                    // Max, not average: a brief Serious spike inside a bucket must stay visible.
                    LineMark(x: .value("Time", point.time), y: .value("State", point.max),
                             series: .value("Segment", index))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Self.color(for: worst))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartXScale(domain: from...to)
        .chartYScale(domain: -0.5...3.5)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 1, 2, 3]) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self), let state = ThermalState(rawValue: Int(v)) {
                        Text(Format.thermal(state))
                    }
                }
            }
        }
    }

    private static func color(for value: Double) -> Color {
        levels.last { Double($0.state.rawValue) <= value.rounded() }?.color ?? .green
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard let history, range != .live else { return }
        let from = Date().addingTimeInterval(-range.rawValue), to = Date()
        do {
            series = try await Task.detached { try history.chartSeries(.thermalState, from: from, to: to) }.value
            error = nil
        } catch {
            self.error = "Could not read history: \(error.localizedDescription)"
        }
    }
}
