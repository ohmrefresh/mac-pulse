import SwiftUI
import Charts
import PulseCore
import PulseCollectors
import PulseEngine
import PulseStore

// Section screens for the dashboard (PRD §16). "Live" charts use the in-memory last few minutes;
// other ranges read PulseStore history.

/// Chart modes for the CPU section. The per-core heatmap needs a series per core, which only the
/// in-memory live buffer has; stored history keeps the combined line and the one-minute load average.
private enum CPUChartMode: String, CaseIterable, Identifiable {
    case cores = "Total + Cores", loadAverage = "Load Average"
    var id: Self { self }
}

/// After `docs/prd/Redesign_v1.html`: a KPI strip that jumps to its section, CPU as a total line over a
/// per-core heatmap, GPU beside Thermal, and Memory in GB with its figures to the right.
struct PerformanceView: View {
    let metrics: LiveMetrics
    /// Memory header: opens the Timeline filtered to memory events.
    let showMemoryTimeline: () -> Void
    @State private var range: ChartRange = .live
    @State private var cpuMode: CPUChartMode = .cores
    /// The Total chart's plot area, which the heatmap below it lines up with.
    @State private var cpuPlot: CGRect?

    private enum Anchor: Hashable { case cpu, gpu, memory, thermal }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    kpiStrip(proxy)
                    cpuSection.id(Anchor.cpu)
                    WeightedHStack {
                        gpuSection.id(Anchor.gpu)
                        thermalSection.id(Anchor.thermal)
                    }
                    memorySection.id(Anchor.memory)
                }
                .padding(24)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if range == .live { LivePill(interval: metrics.samplingInterval) }
                ChartRangePicker(range: $range, liveWindow: liveWindow)
            }
        }
        // Speeds up the GPU tick and the temperature readings only while this page is on screen.
        .onAppear {
            metrics.performanceAppeared()
            metrics.sensorsAppeared()
        }
        .onDisappear {
            metrics.performanceDisappeared()
            metrics.sensorsDisappeared()
        }
    }

    /// What the live buffers span: their capacity at the sampling interval.
    private var liveWindow: TimeInterval { Double(metrics.cpuHistory.capacity) * metrics.samplingInterval }

    // MARK: KPI strip

    private func kpiStrip(_ proxy: ScrollViewProxy) -> some View {
        let m = metrics.memory
        let celsius = metrics.sensors?.cpuCelsius
        return WeightedHStack {
            KPITile(title: "CPU", style: .cpu, health: metrics.cpuHealth,
                    value: metrics.cpu.map { Format.percent($0.totalPercent) }, trend: metrics.cpuTrend) {
                Sparkline(values: metrics.cpuHistory.values, tint: MetricStyle.cpu.tint, domain: 0...100, height: 30)
            } action: { jump(proxy, .cpu) }
            KPITile(title: "GPU", style: .gpu, health: nil,
                    value: metrics.gpu.map { Format.percent($0.utilizationPercent) }, trend: metrics.gpuTrend) {
                Sparkline(values: metrics.gpuHistory.values, tint: MetricStyle.gpu.tint, domain: 0...100, height: 30)
            } action: { jump(proxy, .gpu) }
            KPITile(title: "Memory", style: .memory, health: m?.pressure?.health,
                    value: m.map { Format.percent($0.usedPercent) },
                    caption: m.map { memoryCaption($0) }) {
                MeterBar(fraction: (m?.usedPercent ?? 0) / 100, tint: MetricStyle.memory.tint)
                    .frame(height: 30, alignment: .center)
            } action: { jump(proxy, .memory) }
            // °C when the private sensors report one (ADR 0002), otherwise macOS's own Thermal State.
            KPITile(title: celsius == nil ? "Thermal" : "CPU die", style: .temperature,
                    health: metrics.thermal?.health,
                    value: celsius.map(Format.celsius) ?? metrics.thermal.map(Format.thermal),
                    trend: celsius == nil ? nil : metrics.temperatureTrend,
                    trendFormat: { "\(Int(abs($0).rounded()))°" }) {
                if celsius != nil {
                    Sparkline(values: metrics.temperatureHistory.values, tint: MetricStyle.temperature.tint, height: 30)
                }
            } action: { jump(proxy, .thermal) }
        }
    }

    private func jump(_ proxy: ScrollViewProxy, _ anchor: Anchor) {
        withAnimation(.snappy) { proxy.scrollTo(anchor, anchor: .top) }
    }

    private func memoryCaption(_ m: MemoryReading) -> String {
        var caption = "\(Format.memoryUsage(used: m.usedBytes, total: m.totalBytes))"
        if m.swapUsedBytes > 0 { caption += " · \(Format.gigabytes(m.swapUsedBytes, places: 1)) GB swap" }
        return caption
    }

    // MARK: CPU

    private var cpuSection: some View {
        Section2(title: "CPU", subtitle: cpuSubtitle) {
            Picker("Mode", selection: $cpuMode) {
                ForEach(CPUChartMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            ChartWithRail(rail: StatRail(rows: cpuRows)) {
                VStack(alignment: .leading, spacing: 8) {
                    cpuChart
                    if let note = cpuChartNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// "Apple M5 Pro · 10 Performance + 5 Efficiency cores", in the kernel's own cluster names.
    private var cpuSubtitle: String? {
        let clusters = metrics.cpuTopology.clusters
            .map { "\($0.logicalCount) \($0.name)" }
            .joined(separator: " + ")
        let parts = [metrics.processorName, clusters.isEmpty ? nil : clusters + " cores"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var cpuChart: some View {
        switch (range, cpuMode) {
        case (.live, .cores):
            VStack(alignment: .leading, spacing: 6) {
                TimeSeriesChart(series: [.init(name: "Total", values: metrics.cpuHistory.values, tint: MetricStyle.cpu.tint)],
                                interval: metrics.samplingInterval, window: liveWindow, maximum: 100,
                                format: { "\(Int($0))%" }, showsLegend: false, accessibilityTitle: "CPU usage")
                    .frame(height: 110)
                    .onPreferenceChange(ChartPlotFrameKey.self) { [$cpuPlot] frame in
                        $cpuPlot.wrappedValue = frame
                    }
                if !metrics.perCoreHistory.isEmpty, let plot = cpuPlot {
                    // The same minutes as the Total line, column under sample.
                    CoreHeatmap(cores: metrics.perCoreHistory.map(\.values), tint: MetricStyle.cpu.tint,
                                columns: metrics.cpuHistory.capacity)
                        .frame(width: plot.width)
                        .padding(.leading, plot.minX)
                }
            }
        case (.live, .loadAverage):
            TimeSeriesChart(series: [.init(name: "Load (1m)", values: metrics.loadHistory.values, tint: MetricStyle.cpu.tint)],
                            interval: metrics.samplingInterval, window: liveWindow, format: Format.load,
                            accessibilityTitle: "Load average")
                .frame(height: 200)
        case (_, .loadAverage):
            HistoryChart(history: metrics.history,
                         lines: [.init(kind: .loadAverage1, name: "Load (1m)", tint: MetricStyle.cpu.tint)],
                         range: range, format: Format.load, accessibilityTitle: "Load average")
                .frame(height: 200)
        default:
            HistoryChart(history: metrics.history,
                         lines: [.init(kind: .cpuPercent, name: "CPU", tint: MetricStyle.cpu.tint)],
                         range: range, maximum: 100, format: { "\(Int($0))%" },
                         accessibilityTitle: "CPU usage")
                .frame(height: 200)
        }
    }

    private var cpuChartNote: String? {
        switch (range, cpuMode) {
        case (.live, .cores):
            let count = metrics.perCoreHistory.count
            return count == 0 ? nil : "Total above; below, one row per logical core, shaded by load from 0 to 100%."
        case (_, .cores):
            return "Per-core detail is live only — showing total CPU for this range."
        case (_, .loadAverage) where range != .live:
            return "Runnable threads averaged over one minute."
        default:
            return nil
        }
    }

    private var cpuRows: [StatRail.Row] {
        let cores = metrics.cpu?.perCorePercent ?? []
        let busiest = cores.indices.max { cores[$0] < cores[$1] }
        let current = metrics.frequency?.cpuCurrentHz
        let maximum = metrics.frequency?.cpuMaxHz ?? metrics.cpuTopology.maxFrequencyHz
        let frequency: String? = switch (current, maximum) {
        case let (c?, m?): "\(Format.frequency(c)) / \(Format.frequency(m))"
        case let (c?, nil): Format.frequency(c)
        case let (nil, m?): "max \(Format.frequency(m))"
        default: nil
        }
        // Appended into one typed array: joining `.init` literals with `+` is too much for CI's type checker.
        var rows: [StatRail.Row] = [
            .init(label: "Total", value: metrics.cpu.map { Format.percent($0.totalPercent) }),
            .init(label: "Frequency", value: frequency),
            .init(label: "Load 1 m · 5 m",
                  value: metrics.loadAverage.map { "\(Format.load($0.oneMinute)) · \(Format.load($0.fiveMinutes))" }),
            .init(label: "Busiest core", value: busiest.map { "Core \($0 + 1) · \(Format.percent(cores[$0]))" }),
            // Below 5% counts as idle: a parked core still shows a percent or two of housekeeping.
            .init(label: "Idle cores", value: cores.isEmpty ? nil : "\(cores.filter { $0 < 5 }.count) of \(cores.count)"),
        ]
        rows += metrics.topProcesses(byCPU: 2).map {
            StatRail.Row(label: $0.name, value: "\(Format.decimal($0.cpuPercent, places: 0))%")
        }
        return rows
    }

    // MARK: GPU

    private var gpuSection: some View {
        Section2(title: "GPU", subtitle: metrics.gpu?.name ?? "No GPU data") {
            Text(gpuSummary ?? "").font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        } content: {
            gpuChart.frame(height: 180)
        }
    }

    /// "Renderer 58% · 1.22 GB · 578 mW"; parts this Mac does not report are left out.
    private var gpuSummary: String? {
        let gpu = metrics.gpu
        let parts = [gpu?.rendererPercent.map { "Renderer \(Format.percent($0))" },
                     gpu?.memoryInUseBytes.map(Format.memory),
                     metrics.frequency?.gpuPowerWatts.map(Format.watts)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var gpuChart: some View {
        if range == .live {
            TimeSeriesChart(series: [.init(name: "GPU", values: metrics.gpuHistory.values, tint: MetricStyle.gpu.tint)],
                            interval: metrics.gpuInterval,
                            window: Double(metrics.gpuHistory.capacity) * metrics.gpuInterval,
                            maximum: 100, format: { "\(Int($0))%" },
                            accessibilityTitle: "GPU usage",
                            // Distinguish "not yet" from "never": some Macs report no GPU counters.
                            emptyMessage: metrics.gpu == nil ? "No GPU data on this Mac." : nil)
        } else {
            HistoryChart(history: metrics.history,
                         lines: [.init(kind: .gpuPercent, name: "GPU", tint: MetricStyle.gpu.tint)],
                         range: range, maximum: 100, format: { "\(Int($0))%" },
                         accessibilityTitle: "GPU usage")
        }
    }

    // MARK: Thermal

    private var thermalSection: some View {
        Section2(title: "Thermal", subtitle: metrics.thermal.map { "State \(Format.thermal($0))" }) {
            Text(metrics.sensors.flatMap { Format.fans($0.fans) } ?? "")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        } content: {
            thermalChart.frame(height: 180)
        }
    }

    /// Only the sensors this Mac reports (ADR 0002): each line is drawn when it has readings.
    private var thermalLines: [(name: String, kind: MetricKind, style: MetricStyle, series: TimedSeries)] {
        [("CPU", .cpuTemperatureC, .temperature, metrics.temperatureHistory),
         ("SSD", .ssdTemperatureC, .ssdTemperature, metrics.ssdTemperatureHistory),
         ("Battery", .batteryTemperatureC, .batteryTemperature, metrics.batteryTemperatureHistory)]
    }

    @ViewBuilder private var thermalChart: some View {
        if metrics.sensors.map({ $0.sensors.isEmpty }) ?? false {
            InlineEmpty("No temperature sensors on this Mac. Thermal State comes from macOS.")
        } else if range == .live {
            TimedLineChart(lines: thermalLines.filter { !$0.series.samples.isEmpty }
                               .map { .init(name: $0.name, samples: $0.series.samples, tint: $0.style.tint) },
                           window: liveWindow, maximum: 100, format: { "\(Int($0))°" })
        } else {
            HistoryChart(history: metrics.history,
                         lines: thermalLines.map { .init(kind: $0.kind, name: $0.name, tint: $0.style.tint) },
                         range: range, maximum: 100, format: { "\(Int($0))°C" },
                         accessibilityTitle: "Temperatures")
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        Section2(title: "Memory", subtitle: metrics.memory.map { "\(Format.gigabytes($0.totalBytes, places: 0)) GB unified" }) {
            HStack(spacing: 8) {
                if let pressure = metrics.memory?.pressure {
                    HealthBadge(level: pressure.health, label: pressureLabel(pressure.health))
                }
                Button("Pressure History", action: showMemoryTimeline).controlSize(.small)
            }
        } content: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    memoryChart.frame(minWidth: 380)
                    memoryBreakdown.frame(width: 300)
                }
                VStack(alignment: .leading, spacing: 16) {
                    memoryChart
                    memoryBreakdown
                }
            }
        }
    }

    /// "Pressure Warning · since 13:58"; the start comes from the live timeline and is left out
    /// once that event has aged out.
    private func pressureLabel(_ level: HealthLevel) -> String {
        let label = "Pressure \(Format.health(level))"
        guard level >= .warning,
              let since = metrics.recentEvents.last(where: { $0.category == .memory && $0.severity == level })?.time
        else { return label }
        return label + " · since \(since.formatted(date: .omitted, time: .shortened))"
    }

    private var memoryChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if range == .live, let total = metrics.memory?.totalBytes {
                    let gib = Double(total) / 1_073_741_824
                    TimeSeriesChart(series: memorySeries(scale: gib / 100), interval: metrics.samplingInterval,
                                    window: liveWindow, maximum: gib, format: { "\(Int($0.rounded())) GB" }, stacked: true,
                                    accessibilityTitle: "Memory in use, by kind")
                } else {
                    HistoryChart(history: metrics.history,
                                 lines: [.init(kind: .memoryPercent, name: "Used", tint: MetricStyle.memory.tint)],
                                 range: range, maximum: 100, format: { "\(Int($0))%" },
                                 accessibilityTitle: "Memory in use")
                }
            }
            .frame(height: 220)
            if range != .live {
                Text("The memory split is live only — showing total used for this range.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Bands add up to Memory Used plus Cached Files, in GB (the buffers hold % of installed RAM).
    private func memorySeries(scale: Double) -> [TimeSeriesChart.Series] {
        memoryParts.map { part in
            TimeSeriesChart.Series(name: part.name, values: part.history.values.map { $0 * scale }, tint: part.tint)
        }
    }

    private var memoryParts: [(name: String, history: RecentSeries, tint: Color)] {
        [("App", metrics.memoryAppHistory, MetricStyle.memory.shade(0, of: 4)),
         ("Wired", metrics.memoryWiredHistory, MetricStyle.memory.shade(1, of: 4)),
         ("Compressed", metrics.memoryCompressedHistory, MetricStyle.memory.shade(2, of: 4)),
         ("Cached files", metrics.memoryCachedHistory, MetricStyle.memory.shade(3, of: 4))]
    }

    @ViewBuilder private var memoryBreakdown: some View {
        if let m = metrics.memory {
            let total = Double(max(m.totalBytes, 1))
            let parts: [(String, UInt64, Color)] = [
                ("App", m.appBytes, MetricStyle.memory.shade(0, of: 4)),
                ("Wired", m.wiredBytes, MetricStyle.memory.shade(1, of: 4)),
                ("Compressed", m.compressedBytes, MetricStyle.memory.shade(2, of: 4)),
                ("Cached files", m.cachedFilesBytes, MetricStyle.memory.shade(3, of: 4)),
            ]
            VStack(alignment: .leading, spacing: 12) {
                FigureText(number: Format.gigabytes(m.usedBytes, places: 1),
                           unit: "/ \(Format.gigabytes(m.totalBytes, places: 0)) GB in use", size: .title, unitSize: .callout)
                StackedMeter(segments: parts.map { .init(fraction: Double($0.1) / total, tint: $0.2) }, height: 12)
                VStack(spacing: 6) {
                    ForEach(parts, id: \.0) { name, bytes, tint in
                        breakdownRow(name, Format.memory(bytes), dot: tint)
                    }
                    breakdownRow("Free", Format.memory(m.freeBytes), dot: .secondary)
                }
                Divider()
                breakdownRow("Swap used", Format.memory(m.swapUsedBytes), dot: nil)
                if let advice = memoryAdvice(m) {
                    Text(advice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            InlineEmpty("Memory figures appear with the first sample.")
        }
    }

    private func breakdownRow(_ label: String, _ value: String, dot: Color?) -> some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    /// Under pressure only, and hedged: what is measured, what it likely costs, who holds the most.
    /// It names the largest process but never predicts what quitting it would do.
    private func memoryAdvice(_ m: MemoryReading) -> String? {
        guard let level = m.pressure?.health, level >= .warning else { return nil }
        let squeezed = Format.gigabytes(m.compressedBytes + m.swapUsedBytes, places: 1)
        var line = "Compressed + swap is \(squeezed) GB — likely costing CPU to fit memory."
        if let top = metrics.topProcesses(byMemory: 1).first {
            line += " \(top.name) uses the most (\(Format.memory(top.memoryBytes)))."
        }
        return line
    }
}

/// One Performance KPI: name and status, the figure, its Trend or caption, a small chart. The whole
/// tile is a button that scrolls to the section it summarises.
private struct KPITile<Chart: View>: View {
    let title: String
    let style: MetricStyle
    let health: HealthLevel?
    let value: String?
    var trend: Double?
    var trendFormat: (Double) -> String = { Format.percent(abs($0)).replacingOccurrences(of: "%", with: " pt") }
    var caption: String?
    @ViewBuilder let chart: Chart
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(style.tint).frame(width: 7, height: 7)
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    if let health, health >= .warning {
                        Text("· \(Format.health(health))")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(health.tint.readableInk(on: .card, minimum: 4.5))
                    }
                }
                .lineLimit(1)
                Text(value ?? "—").font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1)
                Group {
                    if let caption {
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        DeltaLabel(value: trend, format: trendFormat)
                    }
                }
                .frame(height: 16, alignment: .leading)
                chart.frame(height: 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardBackground(padding: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Go to \(title)")
    }
}

/// "● Live · 1 s" — the live range and the sampling interval it runs at.
private struct LivePill: View {
    let interval: TimeInterval

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("Live · \(Format.decimal(interval, places: interval < 1 ? 1 : 0)) s")
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .fixedSize()
    }
}

/// Lines over wall-clock time, for readings on an irregular cadence (sensors): the x-axis spans the
/// live window ending now, so every chart on the page covers the same minutes.
private struct TimedLineChart: View {
    struct Line: Identifiable {
        let name: String
        let samples: [(time: Date, value: Double)]
        let tint: Color
        var id: String { name }
    }

    let lines: [Line]
    let window: TimeInterval
    var maximum: Double
    var format: (Double) -> String

    var body: some View {
        let end = lines.compactMap { $0.samples.last?.time }.max() ?? .now
        // The same fixed span as the sample charts beside it, so nothing re-fits as readings arrive.
        let start = end.addingTimeInterval(-window)
        if lines.isEmpty {
            InlineEmpty("Temperatures appear with the first sensor reading.")
        } else {
            Chart {
                ForEach(lines) { line in
                    ForEach(Array(line.samples.filter { $0.time >= start }.enumerated()), id: \.offset) { _, sample in
                        LineMark(x: .value("Time", sample.time), y: .value(line.name, sample.value),
                                 series: .value("Sensor", line.name))
                            .interpolationMethod(ChartCurve.line)
                            .foregroundStyle(by: .value("Sensor", line.name))
                            .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                }
            }
            .chartForegroundStyleScale(domain: lines.map(\.name), range: lines.map(\.tint))
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...maximum)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)) } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .accessibilityLabel("Temperatures: " + lines.compactMap { line in
                line.samples.last.map { "\(line.name) \(format($0.value))" }
            }.joined(separator: ", "))
        }
    }
}

struct NetworkDetailView: View {
    let metrics: LiveMetrics
    @State private var range: ChartRange = .live

    /// Four probes of one metric family: step the family's own tint. A second hue here reads
    /// as a second metric, and orange and purple already mean Temperature and Memory.
    /// Computed, so each render builds new (never-equal) tints — the chart keys by kind.
    static var latencyLines: [HistoryChart.Line] {
        [.init(kind: .latencyMs, name: "Internet", tint: MetricStyle.internet.shade(0, of: 4)),
         .init(kind: .secondaryLatencyMs, name: "Second target", tint: MetricStyle.internet.shade(1, of: 4)),
         .init(kind: .gatewayLatencyMs, name: "Gateway", tint: MetricStyle.internet.shade(2, of: 4)),
         .init(kind: .dnsLatencyMs, name: "DNS", tint: MetricStyle.internet.shade(3, of: 4))]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Section2(title: "Throughput", subtitle: metrics.network?.interface.map { "Interface \($0)" } ?? "No connection") {
                    Group {
                        if range == .live {
                            TimeSeriesChart(series: [.init(name: "Download", values: metrics.downHistory.values, tint: MetricStyle.network.tint),
                                                     .init(name: "Upload", values: metrics.upHistory.values, tint: MetricStyle.upload.tint)],
                                            interval: metrics.samplingInterval,
                                            window: Double(metrics.downHistory.capacity) * metrics.samplingInterval,
                                            format: { MenuBarFormatter.rate($0) + "/s" })
                        } else {
                            HistoryChart(history: metrics.history,
                                         lines: [.init(kind: .networkDownBytesPerSec, name: "Download", tint: MetricStyle.network.tint),
                                                 .init(kind: .networkUpBytesPerSec, name: "Upload", tint: MetricStyle.upload.tint)],
                                         range: range, format: { MenuBarFormatter.rate($0) + "/s" })
                        }
                    }
                    .frame(height: 180)
                }
                Section2(title: "Latency", subtitle: range == .live ? "Probe every 5 s · gaps are timeouts" : "Internet, second target, gateway and DNS") {
                    Group {
                        if range == .live {
                            TimeSeriesChart(series: [.init(name: "Latency", values: metrics.latencyHistory.values, tint: MetricStyle.internet.tint)],
                                            interval: 5, window: Double(metrics.latencyHistory.capacity) * 5,
                                            format: { "\(Int($0)) ms" })
                        } else {
                            HistoryChart(history: metrics.history, lines: Self.latencyLines,
                                         range: range, format: { "\(Int($0)) ms" })
                        }
                    }
                    .frame(height: 180)
                    if let h = metrics.networkHealth {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            GridRow {
                                Text("Status").foregroundStyle(.secondary)
                                HealthBadge(level: h.health, label: h.connectivity == .offline ? "Offline" : nil)
                            }
                            probeRows("Internet", h.internet)
                            probeRows("Second target", h.secondary)
                            probeRows("Gateway", h.gateway)
                            if let dns = h.dns {
                                KeyValue("DNS resolver", dns.server)
                                KeyValue("  Lookup time", dns.latencyMs.map { "\(Int($0.rounded())) ms" } ?? "timeout")
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ChartRangePicker(range: $range) }
        }
    }

    @ViewBuilder
    private func probeRows(_ title: String, _ probe: ProbeReading?) -> some View {
        if let probe {
            KeyValue(title, probe.address)
            KeyValue("  Latency", probe.latencyMs.map { "\(Int($0.rounded())) ms" } ?? "timeout")
            KeyValue("  Packet loss (1 min)", probe.lossPercent.map(Format.percent))
        }
    }
}

struct StorageView: View {
    let metrics: LiveMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let d = metrics.disk {
                VStack(alignment: .leading, spacing: 12) {
                    Text(d.volumeName ?? "Startup disk").font(.title3.weight(.semibold))
                    UsageBar(fraction: Double(d.usedBytes) / Double(max(d.totalBytes, 1)), tint: MetricStyle.disk.tint)
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        KeyValue("Capacity", Format.bytes(d.totalBytes))
                        KeyValue("Used", Format.bytes(d.usedBytes))
                        KeyValue("Available", Format.bytes(d.availableBytes))
                    }
                    Text("Available includes purgeable space, matching Finder. Refreshed every 60 s.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            } else {
                ContentUnavailableView("No disk data yet", systemImage: "internaldrive")
            }
            Spacer()
        }
        .padding(24)
    }
}

struct BatteryView: View {
    let metrics: LiveMetrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let b = metrics.battery {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Format.percent(b.percent)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                            Spacer()
                            if let c = b.condition { HealthBadge(level: c.health, label: Format.batteryCondition(c)) }
                        }
                        Sparkline(values: metrics.batteryHistory.values, tint: MetricStyle.battery.tint,
                                  points: 120, domain: 0...100, height: 70)
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            KeyValue("State", Format.batteryState(b))
                            KeyValue("Condition", b.condition.map(Format.batteryCondition))
                            KeyValue("Cycle count", b.cycleCount.map(String.init))
                            KeyValue("Maximum capacity", b.maximumCapacityPercent.map(Format.percent))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground()
                } else {
                    Text("This Mac has no internal battery.").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) { peripherals }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground()
            }
            .padding(24)
        }
    }

    @ViewBuilder private var peripherals: some View {
        Text("Accessories").font(.headline)
        if metrics.peripheralBatteries.isEmpty {
            InlineEmpty("No Bluetooth accessories reporting a battery level.")
        } else {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(metrics.peripheralBatteries) { KeyValue($0.name, "\($0.percent)%") }
            }
        }
    }
}

// MARK: - Shared pieces

private struct Section2<Content: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing
    let content: Content

    init(title: String, subtitle: String?, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SubsectionHeader(title, subtitle: subtitle)
                Spacer(minLength: 12)
                trailing
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension Section2 where Trailing == EmptyView {
    init(title: String, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// A grid row that omits itself when the value is nil: the Nil Row Rule, applied to key/value pairs.
private struct KeyValue: View {
    let key: String
    let value: String?
    init(_ key: String, _ value: String?) {
        self.key = key
        self.value = value
    }

    @ViewBuilder
    var body: some View {
        if let value {
            GridRow {
                Text(key).foregroundStyle(.secondary)
                Text(value).monospacedDigit()
            }
        }
    }
}
