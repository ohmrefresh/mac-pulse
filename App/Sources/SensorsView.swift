import SwiftUI
import Charts
import PulseCore
import PulseCollectors
import PulseEngine
import PulseStore

/// Sensors page (after `docs/prd/mock_v2.html`): the Thermal State banner, a card per temperature
/// this Mac reports, the stored temperature chart beside every Sensor, and fans. Temperatures are
/// informational; only the Thermal State carries a Health Level.
struct SensorsView: View {
    let metrics: LiveMetrics
    @Bindable var settings: AppSettings
    let showThermalHistory: () -> Void
    @State private var range: ChartRange = .hour
    @Environment(\.temperatureUnit) private var unit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let state = metrics.thermal {
                    ThermalBanner(state: state, since: ThermalSummary.since(metrics.thermalChanges.map { ($0.state, $0.date) }, current: state),
                                  detail: ThermalSummary.detail(metrics.sensors, unit: unit),
                                  showHistory: showThermalHistory)
                }
                if let s = metrics.sensors, !s.sensors.isEmpty {
                    cards(s)
                    HStack(alignment: .top, spacing: 16) {
                        temperatureChart(s)
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)
                        SensorTable(sensors: s.sensors, extremes: metrics.sensorExtremes)
                            .frame(minWidth: 330, maxWidth: 400)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    unavailableNote
                }
                if let fans = metrics.sensors?.fans, !fans.isEmpty {
                    FanStrip(fans: fans)
                }
                Label("Temperatures and fans use undocumented macOS interfaces and may be unavailable after a macOS update.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .toolbar { toolbarItems }
        .onAppear(perform: metrics.sensorsAppeared)
        .onDisappear(perform: metrics.sensorsDisappeared)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Sensors are read every 5 s while a temperature view is on screen (Cadence `.sensors`).
            LivePill(interval: 5)
            ChartRangePicker(range: $range, options: ChartRange.sensors)
            Picker("Temperature unit", selection: $settings.temperatureUnit) {
                ForEach(TemperatureUnit.allCases) { Text($0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show temperatures in Celsius or Fahrenheit, here and in the menu bar")
        }
    }

    // MARK: Cards

    /// A card per temperature this Mac actually reports. A machine without an SSD or battery probe
    /// gets three cards or two, never a card with a dash in it.
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

    // MARK: Chart

    /// Stored temperatures, a line only for each reading this Mac reports, and a legend carrying
    /// each line's reading now (end-of-line labels collided when two sensors sat a few degrees apart).
    private func temperatureChart(_ s: SensorsReading) -> some View {
        let lines: [(line: HistoryChart.Line, now: Double?)] = [
            (.init(kind: .hottestTemperatureC, name: "Hottest", tint: MetricStyle.temperature.tint), s.hottest?.celsius),
            (.init(kind: .cpuTemperatureC, name: "CPU", tint: MetricStyle.cpu.tint), s.cpuCelsius),
            (.init(kind: .ssdTemperatureC, name: "SSD", tint: MetricStyle.ssdTemperature.tint), s.ssdCelsius),
            (.init(kind: .batteryTemperatureC, name: "Battery", tint: MetricStyle.batteryTemperature.tint), s.batteryCelsius),
        ].filter { $0.now != nil }
        return Section2(title: "Temperature", subtitle: range.spanName) {
            VStack(alignment: .leading, spacing: 10) {
                HistoryChart(history: metrics.history, lines: lines.map(\.line), range: range, maximum: 100,
                             format: { [unit] in Format.temperature($0, unit) }, showsHoverDetails: true,
                             accessibilityTitle: "Temperatures", showsLegend: false,
                             yTicks: unit.axisTicks(celsius: 0...100))
                    .frame(minHeight: 300)
                HStack(spacing: 16) {
                    ForEach(lines, id: \.line.kind) { entry in
                        HStack(spacing: 5) {
                            Circle().fill(entry.line.tint).frame(width: 7, height: 7)
                            Text(entry.line.name).foregroundStyle(.secondary)
                            if let now = entry.now {
                                Text(Format.temperature(now, unit)).fontWeight(.medium).monospacedDigit()
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Spacer(minLength: 0)
                    Text("now").foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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

// MARK: - Thermal summary

/// The banner's wording, kept out of the view so it can be tested.
enum ThermalSummary {
    /// How long the current Thermal State has held. `atLeast` when the only record is the reading
    /// taken at launch: the state held since then, but may have started earlier.
    struct Since: Equatable {
        let date: Date
        let atLeast: Bool
    }

    /// From the in-session change log (newest last; its first entry is the launch reading). A stored
    /// Timeline Event from before launch can't prove the state held while Mac Pulse was not running,
    /// so it is not used.
    static func since(_ changes: [(state: ThermalState, date: Date)], current: ThermalState) -> Since? {
        guard let last = changes.last, last.state == current else { return nil }
        return Since(date: last.date, atLeast: changes.count == 1)
    }

    static func mood(_ state: ThermalState) -> String {
        switch state {
        case .nominal: "Running cool"
        case .fair: "Warming up"
        case .serious: "Running hot"
        case .critical: "Running very hot"
        }
    }

    /// "Running cool — thermal state Nominal for 1h 5m".
    static func headline(_ state: ThermalState, since: Since?, now: Date = Date()) -> String {
        var line = "\(mood(state)) — thermal state \(Format.thermal(state))"
        // "for at least <1m" just after launch says nothing.
        if let since, !(since.atLeast && now.timeIntervalSince(since.date) < 60) {
            line += " for \(since.atLeast ? "at least " : "")\(Format.running(since: since.date, now: now))"
        }
        return line
    }

    /// "Hottest sensor is PMU tcal at 52°C · fans at 30% of max". Each part only when this Mac
    /// reports it; nil when neither is.
    static func detail(_ sensors: SensorsReading?, unit: TemperatureUnit) -> String? {
        guard let sensors else { return nil }
        let hottest = sensors.hottest.map { "Hottest sensor is \($0.name) at \(Format.temperature($0.celsius, unit))" }
        let fastest = sensors.fans.max { $0.rpm < $1.rpm }
        let fan = fastest.flatMap { fans(rpm: $0.rpm, maxRPM: $0.maxRPM) }
        return [hottest, fan].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    /// The fastest fan against its own maximum; its speed alone when no maximum is reported.
    static func fans(rpm: Double, maxRPM: Double?) -> String {
        if rpm < 1 { return "fans stopped" }
        if let maxRPM, maxRPM > 0 { return "fans at \(Format.percent(min(rpm / maxRPM, 1) * 100)) of max" }
        return "fans at \(Format.decimal(rpm, places: 0)) rpm"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The Thermal State first: its mood and how long it has held, the hottest Sensor and fans, and
/// macOS's four steps with the current one lit.
private struct ThermalBanner: View {
    let state: ThermalState
    let since: ThermalSummary.Since?
    let detail: String?
    let showHistory: () -> Void

    /// Carried over from the thermal history chart: each step must clear 3:1 as a mark, and
    /// `HealthLevel` alone can't tell Nominal from Fair (both Healthy).
    private static let steps: [(state: ThermalState, color: Color)] = [
        (.nominal, .green), (.fair, .yellow), (.serious, .orange), (.critical, .red),
    ]

    var body: some View {
        // Periodic so "for 12m" advances without waiting for the next sensor reading.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            NoticeBanner(level: state.health, symbol: state.health.symbol,
                         title: ThermalSummary.headline(state, since: since, now: context.date),
                         detail: detail) {
                HStack(spacing: 16) {
                    legend
                    Button("View history", action: showHistory)
                        .buttonStyle(.link)
                        .help("Open the Timeline filtered to thermal events")
                }
            }
        }
    }

    private var legend: some View {
        let backdrop = Color.Backdrop.tintedFill(NoticeBanner<EmptyView>.fill)
        return HStack(spacing: 10) {
            ForEach(Self.steps, id: \.state) { step in
                let current = step.state == state
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(step.color.readableInk(on: backdrop, minimum: 3))
                        .frame(width: 9, height: 9)
                        .opacity(current ? 1 : 0.35)
                    Text(Format.thermal(step.state))
                        .fontWeight(current ? .semibold : .regular)
                        .foregroundStyle(current ? Color.primary : Color.secondary)
                }
            }
        }
        .font(.caption)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thermal state scale: Nominal, Fair, Serious, Critical. Now \(Format.thermal(state)).")
    }
}

// MARK: - Temperature card

/// Name, value, change over the last 15 minutes with a sparkline, and a bar placing the value.
struct TemperatureCard: View {
    let title: String
    let caption: String?
    let style: MetricStyle
    let value: Double
    let series: TimedSeries
    @Environment(\.temperatureUnit) private var unit

    /// Where the bar starts and fills, in °C. A display scale for placing the value, not a
    /// threshold: nothing here is judged hot or cool by it.
    static let barScale = 20.0...100.0

    var body: some View {
        let figure = Format.temperatureFigure(value, unit)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: style.symbol).foregroundStyle(style.tint)
                Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                if let caption {
                    Text("· \(caption)").font(.callout).foregroundStyle(.secondary).truncationMode(.middle)
                }
            }
            .lineLimit(1)
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    FigureText(number: figure.number, unit: figure.unit, size: .title, unitSize: .callout)
                    change.frame(height: 16, alignment: .leading)
                }
                .fixedSize()
                Spacer(minLength: 8)
                // Needs two readings to draw a line; until then the value stands alone.
                if let values = Self.sparkValues(series.samples) {
                    // Stretched over as many slots as there are readings: Sparkline's default 60
                    // slots put a few minutes of 5 s readings in a sliver at the right edge.
                    Sparkline(values: values, tint: style.tint, points: values.count,
                              domain: Self.sparkDomain(values), height: 36, lineWidth: 1.6, filled: false)
                        .frame(maxWidth: 180)
                }
            }
            MeterBar(fraction: (value - Self.barScale.lowerBound) / (Self.barScale.upperBound - Self.barScale.lowerBound),
                     tint: style.tint, height: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(padding: 14)
        .accessibilityElement(children: .combine)
    }

    /// The readings of the last `window` seconds (the span the change line reports), oldest first;
    /// nil with fewer than two, which cannot make a line.
    static func sparkValues(_ samples: [(time: Date, value: Double)], window: TimeInterval = 900) -> [Double]? {
        guard let newest = samples.last?.time else { return nil }
        let values = samples.filter { newest.timeIntervalSince($0.time) <= window }.map(\.value)
        return values.count >= 2 ? values : nil
    }

    /// The sparkline's y range: the readings' own, at least 6 °C tall and centred on them, so a
    /// steady sensor draws a flat line at mid-height rather than a fitted band, and a 1 °C wobble
    /// does not fill the card.
    static func sparkDomain(_ values: [Double], minimumSpan: Double = 6) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...minimumSpan }
        let half = max(high - low, minimumSpan) / 2, middle = (low + high) / 2
        return (middle - half)...(middle + half)
    }

    /// "↑ 2°C in 15 min". Until the series spans 15 minutes there is no change to report, so the
    /// row is absent rather than showing a minus sign next to a dash.
    @ViewBuilder
    private var change: some View {
        if let delta = series.change(over: 900) {
            let shown = Int(unit.scale(delta).rounded())
            HStack(spacing: 3) {
                // Direction carries it; status colour belongs to Health Level alone.
                Image(systemName: shown > 0 ? "arrow.up" : (shown < 0 ? "arrow.down" : "minus"))
                Text(shown == 0 ? "flat" : Format.temperatureChange(delta, unit))
                Text("in 15 min").foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(shown == 0 ? "No change over the last 15 minutes"
                                : "\(shown > 0 ? "Up" : "Down") \(Format.temperatureChange(delta, unit)) over the last 15 minutes")
        }
    }
}

// MARK: - Sensor table

private struct SensorTable: View {
    let sensors: [TemperatureSensor]
    let extremes: [String: ClosedRange<Double>]
    @State private var sort: Sort = .hottest
    @State private var showAll = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.temperatureUnit) private var unit

    enum Sort: String, CaseIterable { case hottest = "Hottest", name = "By name" }

    private static let collapsedCount = 9

    var body: some View {
        let scale = SensorRange.scale(extremes.filter { name, _ in sensors.contains { $0.name == name } }.map(\.value))
        Section2(title: "All sensors", subtitle: "\(sensors.count)") {
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("Sensor")
                    Text("Now").gridColumnAlignment(.trailing)
                    Text("Range since launch")
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(visible) { sensor in
                    GridRow {
                        DotLabel(text: sensor.name, tint: Self.tint(for: sensor.name))
                            .truncationMode(.middle)
                        Text(Format.temperature(sensor.celsius, unit)).fontWeight(.medium).monospacedDigit()
                        if let range = extremes[sensor.name], let scale {
                            RangeMeter(range: range, now: sensor.celsius, scale: scale, tint: Self.tint(for: sensor.name))
                                .help("\(Format.temperature(range.lowerBound, unit)) – \(Format.temperature(range.upperBound, unit)) since launch")
                        } else {
                            Color.clear.frame(width: RangeMeter.width, height: 1)
                        }
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
            HStack {
                if sensors.count > Self.collapsedCount {
                    Button(showAll ? "Show fewer" : "Show \(sensors.count - Self.collapsedCount) more") {
                        // The one animation the app ships; Reduce Motion gets the same disclosure
                        // without the expansion.
                        withAnimation(reduceMotion ? nil : .snappy) { showAll.toggle() }
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                HStack(spacing: 4) {
                    Capsule().fill(.primary).frame(width: 2, height: 9)
                    Text("now · bar = min–max")
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Tick is the current reading; the bar spans the lowest to highest since launch")
            }
            .padding(.top, 4)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var visible: [TemperatureSensor] {
        let sorted = sort == .hottest
            ? sensors.sorted { $0.celsius > $1.celsius }
            : sensors.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return showAll ? sorted : Array(sorted.prefix(Self.collapsedCount))
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

/// The shared °C scale the "range since launch" bars are drawn on.
enum SensorRange {
    /// Lowest minimum to highest maximum, widened to at least 4 °C so one steady sensor is not
    /// drawn as a full-width bar. Nil with no ranges.
    static func scale(_ ranges: [ClosedRange<Double>]) -> ClosedRange<Double>? {
        guard let low = ranges.map(\.lowerBound).min(), let high = ranges.map(\.upperBound).max() else { return nil }
        let pad = max(4 - (high - low), 0) / 2
        return (low - pad)...(high + pad)
    }
}

/// Lowest-to-highest since launch as a bar on the table's shared scale, with a tick at now.
private struct RangeMeter: View {
    static let width: CGFloat = 110

    let range: ClosedRange<Double>
    let now: Double
    let scale: ClosedRange<Double>
    let tint: Color

    var body: some View {
        let span = max(scale.upperBound - scale.lowerBound, 0.001)
        func x(_ value: Double) -> CGFloat { Self.width * min(max((value - scale.lowerBound) / span, 0), 1) }
        return Capsule()
            .fill(.quaternary)
            .frame(width: Self.width, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(tint.opacity(0.75))
                    .frame(width: max(x(range.upperBound) - x(range.lowerBound), 3), height: 4)
                    .offset(x: x(range.lowerBound))
            }
            .overlay(alignment: .leading) {
                Capsule().fill(.primary)
                    .frame(width: 2, height: 10)
                    .offset(x: min(max(x(now) - 1, 0), Self.width - 2))
            }
            .frame(height: 10)
            .accessibilityHidden(true)
    }
}

// MARK: - Fans

/// Every fan in one strip: speed against its maximum where the SMC reports one.
private struct FanStrip: View {
    let fans: [FanReading]

    var body: some View {
        HStack(spacing: 24) {
            Label("Fans", systemImage: "fan").font(.headline).fixedSize()
            ForEach(fans) { fan in
                row(fan)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(padding: 14)
    }

    private func row(_ fan: FanReading) -> some View {
        let fraction = fan.maxRPM.flatMap { $0 > 0 ? min(fan.rpm / $0, 1) : nil }
        return HStack(spacing: 10) {
            Text("Fan \(fan.index + 1)").foregroundStyle(.secondary).fixedSize()
            if let fraction {
                MeterBar(fraction: fraction, tint: MetricStyle.cpu.tint, height: 6).frame(minWidth: 80, maxWidth: 220)
            }
            if fan.rpm < 1 {
                CountChip(text: "Stopped")
            } else {
                HStack(spacing: 0) {
                    Text("\(Format.decimal(fan.rpm, places: 0)) rpm").fontWeight(.semibold)
                    if let fraction { Text(" · \(Format.percent(fraction * 100))").foregroundStyle(.secondary) }
                }
                .monospacedDigit()
                .fixedSize()
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
