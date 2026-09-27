import SwiftUI
import Charts
import PulseCore
import PulseCollectors
import PulseEngine
import PulseStore

// Section screens for the dashboard (PRD §16). "Live" charts use the in-memory last few minutes;
// other ranges read PulseStore history.

/// Chart modes for the CPU section. Per Core needs a series per core, which only the in-memory
/// live buffer has; stored history keeps the combined line and the one-minute load average.
private enum CPUChartMode: String, CaseIterable, Identifiable {
    case perCore = "Per Core", loadAverage = "Load Average", combined = "Combined"
    var id: Self { self }
}

struct PerformanceView: View {
    let metrics: LiveMetrics
    /// Memory Pressure row: opens the Timeline filtered to memory events.
    let showMemoryTimeline: () -> Void
    @State private var range: ChartRange = .live
    @State private var cpuMode: CPUChartMode = .perCore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Performance", subtitle: "CPU, GPU and memory over time.") { ChartRangePicker(range: $range) }
                summaryCards
                cpuSection
                gpuSection
                memorySection
            }
            .padding(24)
        }
        // Speeds up the GPU tick and the temperature card only while this page is on screen.
        .onAppear {
            metrics.performanceAppeared()
            metrics.sensorsAppeared()
        }
        .onDisappear {
            metrics.performanceDisappeared()
            metrics.sensorsDisappeared()
        }
    }

    // MARK: Summary cards

    /// Four across when there is room, two by two when the window is near its 980 pt minimum —
    /// squeezing four cards into that width clips their titles.
    private var summaryCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
            cpuCard
            gpuCard
            memoryCard
            temperatureCard
        }
    }

    private var cpuCard: some View {
        summaryCard(title: "CPU", style: .cpu, health: metrics.cpuHealth,
                    value: metrics.cpu.map { Format.percent($0.totalPercent) },
                    trend: metrics.cpuTrend, caption: metrics.processorName,
                    series: metrics.cpuHistory.values, domain: 0...100)
    }

    private var gpuCard: some View {
        summaryCard(title: "GPU", style: .gpu,
                    value: metrics.gpu.map { Format.percent($0.utilizationPercent) },
                    trend: metrics.gpuTrend,
                    caption: metrics.gpu?.memoryInUseBytes.map { "\(Format.memory($0)) in use" },
                    series: metrics.gpuHistory.values, domain: 0...100)
    }

    private var memoryCard: some View {
        let m = metrics.memory
        return summaryCard(title: "Memory", style: .memory, health: m?.pressure?.health,
                           value: m.map { Format.percent($0.usedPercent) },
                           trend: metrics.memoryTrend,
                           caption: m.map { Format.memoryUsage(used: $0.usedBytes, total: $0.totalBytes) },
                           series: metrics.memoryHistory.values, domain: 0...100)
    }

    /// °C when the private sensors report one (ADR 0002), otherwise macOS's own Thermal State.
    private var temperatureCard: some View {
        let celsius = metrics.sensors?.cpuCelsius
        return summaryCard(title: "Temperature", style: .temperature,
                           health: celsius == nil ? metrics.thermal?.health : nil,
                           value: celsius.map(Format.celsius) ?? metrics.thermal.map(Format.thermal),
                           trend: celsius == nil ? nil : metrics.temperatureTrend,
                           trendFormat: { "\(Int(abs($0).rounded()))°C" },
                           caption: celsius == nil ? "Thermal State" : "CPU die",
                           series: celsius == nil ? [] : metrics.temperatureHistory.values,
                           domain: nil)
    }

    /// Mockup summary card: headline value and its trend on the left, sparkline on the right.
    private func summaryCard(title: String, style: MetricStyle, health: HealthLevel? = nil,
                             value: String?, trend: Double?,
                             trendFormat: @escaping (Double) -> String = { Format.percent(abs($0)) },
                             caption: String?, series: [Double],
                             domain: ClosedRange<Double>?) -> some View {
        MetricCard(title: title, style: style, health: health) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        BigValue(value)
                        DeltaLabel(value: trend, format: trendFormat)
                    }
                    Spacer(minLength: 4)
                    if !series.isEmpty {
                        Sparkline(values: series, tint: style.tint, points: 60, domain: domain, height: 48)
                            .frame(maxWidth: 110)
                    }
                }
                // Full card width, so "Apple M5 Pro" and "18.4 / 24 GB" are not clipped by the sparkline.
                Text(caption ?? " ").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    // MARK: CPU

    private var cpuSection: some View {
        Section2(title: "CPU", subtitle: metrics.processorName) {
            Picker("Mode", selection: $cpuMode) {
                ForEach(CPUChartMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            ChartWithRail(rail: StatRail(rows: cpuRows)) {
                VStack(alignment: .leading, spacing: 6) {
                    cpuChart.frame(height: 200)
                    if let note = cpuChartNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var cpuChart: some View {
        switch (range, cpuMode) {
        case (.live, .perCore):
            TimeSeriesChart(series: perCoreSeries, interval: metrics.samplingInterval, maximum: 100,
                            format: { "\(Int($0))%" }, showsLegend: false,
                            emphasis: { $0 == "Total" ? 2.2 : 1 },
                            accessibilityTitle: "CPU usage per core")
        case (.live, .loadAverage):
            TimeSeriesChart(series: [.init(name: "Load (1m)", values: metrics.loadHistory.values, tint: MetricStyle.cpu.tint)],
                            interval: metrics.samplingInterval, format: Format.load,
                            accessibilityTitle: "Load average")
        case (.live, .combined):
            TimeSeriesChart(series: [.init(name: "CPU", values: metrics.cpuHistory.values, tint: MetricStyle.cpu.tint)],
                            interval: metrics.samplingInterval, maximum: 100, format: { "\(Int($0))%" },
                            accessibilityTitle: "CPU usage")
        case (_, .loadAverage):
            HistoryChart(history: metrics.history,
                         lines: [.init(kind: .loadAverage1, name: "Load (1m)", tint: MetricStyle.cpu.tint)],
                         range: range, format: Format.load, accessibilityTitle: "Load average")
        default:
            HistoryChart(history: metrics.history,
                         lines: [.init(kind: .cpuPercent, name: "CPU", tint: MetricStyle.cpu.tint)],
                         range: range, maximum: 100, format: { "\(Int($0))%" },
                         accessibilityTitle: "CPU usage")
        }
    }

    /// One line per core in the CPU tint at stepped opacity, with the total on top.
    private var perCoreSeries: [TimeSeriesChart.Series] {
        let cores = metrics.perCoreHistory
        return [TimeSeriesChart.Series(name: "Total", values: metrics.cpuHistory.values, tint: MetricStyle.cpu.tint)]
            + cores.enumerated().map { index, series in
                TimeSeriesChart.Series(name: "Core \(index + 1)", values: series.values,
                                       tint: MetricStyle.cpu.shade(index + 1, of: cores.count + 1))
            }
    }

    private var cpuChartNote: String? {
        switch (range, cpuMode) {
        case (.live, .perCore):
            let count = metrics.perCoreHistory.count
            return count == 0 ? nil : "Total plus \(count) logical cores."
        case (_, .perCore):
            return "Per-core detail is live only — showing combined CPU for this range."
        case (_, .loadAverage) where range != .live:
            return "Runnable threads averaged over one minute."
        default:
            return nil
        }
    }

    private var cpuRows: [StatRail.Row] {
        let topology = metrics.cpuTopology
        return [
            .init(label: "Total Usage", value: metrics.cpu.map { Format.percent($0.totalPercent) }),
            .init(label: "Current Frequency", value: metrics.frequency?.cpuCurrentHz.map(Format.frequency)),
            // Apple Silicon reports a ceiling through IOReport; Intel publishes one through sysctl.
            .init(label: "Max Frequency",
                  value: (metrics.frequency?.cpuMaxHz ?? topology.maxFrequencyHz).map(Format.frequency)),
        ]
        // One row per cluster, labelled the way the kernel names it (e.g. "Super", "Performance").
        + topology.clusters.map { .init(label: "Cores (\($0.name))", value: "\($0.logicalCount)") }
        + [
            .init(label: "Logical Processors", value: topology.logicalCount.map(String.init)),
            .init(label: "Load Average (1m)", value: metrics.loadAverage.map { Format.load($0.oneMinute) }),
            .init(label: "Load Average (5m)", value: metrics.loadAverage.map { Format.load($0.fiveMinutes) }),
            .init(label: "Uptime", value: metrics.uptime.map(Format.uptime)),
        ]
    }

    // MARK: GPU

    private var gpuSection: some View {
        Section2(title: "GPU", subtitle: metrics.gpu?.name ?? "No GPU data") {
            ChartWithRail(rail: StatRail(rows: gpuRows)) {
                gpuChart.frame(height: 180)
            }
        }
    }

    @ViewBuilder private var gpuChart: some View {
        if range == .live {
            TimeSeriesChart(series: [.init(name: "GPU", values: metrics.gpuHistory.values, tint: MetricStyle.gpu.tint)],
                            interval: metrics.gpuInterval, maximum: 100, format: { "\(Int($0))%" },
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

    private var gpuRows: [StatRail.Row] {
        let gpu = metrics.gpu
        return [
            .init(label: "Total Usage", value: gpu.map { Format.percent($0.utilizationPercent) }),
            .init(label: "Renderer", value: gpu?.rendererPercent.map(Format.percent)),
            .init(label: "Memory In Use", value: gpu?.memoryInUseBytes.map(Format.memory)),
            .init(label: "Power", value: metrics.frequency?.gpuPowerWatts.map(Format.watts)),
        ]
    }

    // MARK: Memory

    private var memorySection: some View {
        Section2(title: "Memory", subtitle: metrics.memory.map { "\(Format.memory($0.totalBytes)) installed" }) {
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

    private var memoryChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if range == .live {
                    TimeSeriesChart(series: memorySeries, interval: metrics.samplingInterval, maximum: 100,
                                    format: { "\(Int($0))%" }, stacked: true,
                                    accessibilityTitle: "Memory in use, by kind")
                } else {
                    HistoryChart(history: metrics.history,
                                 lines: [.init(kind: .memoryPercent, name: "Used", tint: MetricStyle.memory.tint)],
                                 range: range, maximum: 100, format: { "\(Int($0))%" },
                                 accessibilityTitle: "Memory in use")
                }
            }
            .frame(height: 200)
            if range != .live {
                Text("The memory split is live only — showing total used for this range.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Bands add up to Memory Used plus Cached Files, as a share of installed RAM.
    private var memorySeries: [TimeSeriesChart.Series] {
        [("App Memory", metrics.memoryAppHistory), ("Wired", metrics.memoryWiredHistory),
         ("Compressed", metrics.memoryCompressedHistory), ("Cached Files", metrics.memoryCachedHistory)]
            .enumerated()
            .map { index, pair in
                TimeSeriesChart.Series(name: pair.0, values: pair.1.values,
                                       tint: MetricStyle.memory.shade(index, of: 5))
            }
    }

    @ViewBuilder private var memoryBreakdown: some View {
        if let m = metrics.memory {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    DonutChart(slices: memorySlices(m),
                               centerValue: Format.memory(m.usedBytes), centerCaption: "in use", diameter: 132)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(memorySlices(m)) { slice in
                            HStack(spacing: 6) {
                                Circle().fill(slice.tint).frame(width: 8, height: 8)
                                Text(slice.label).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(Format.memory(UInt64(slice.value))).monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }
                }
                Divider()
                HStack {
                    Text("Swap Used").foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.memory(m.swapUsedBytes)).monospacedDigit()
                }
                .font(.callout)
                Button(action: showMemoryTimeline) {
                    HStack {
                        Text("Memory Pressure").foregroundStyle(.secondary)
                        Spacer()
                        HealthBadge(level: m.pressure?.health ?? .unknown)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show memory events in the Timeline")
            }
        } else {
            Text("No memory data yet").foregroundStyle(.secondary)
        }
    }

    /// Slices sum to installed RAM: Used (app + wired + compressed) plus Cached Files plus Free.
    private func memorySlices(_ m: MemoryReading) -> [DonutChart.Slice] {
        [.init(label: "App Memory", value: Double(m.appBytes), tint: MetricStyle.memory.shade(0, of: 5)),
         .init(label: "Wired", value: Double(m.wiredBytes), tint: MetricStyle.memory.shade(1, of: 5)),
         .init(label: "Compressed", value: Double(m.compressedBytes), tint: MetricStyle.memory.shade(2, of: 5)),
         .init(label: "Cached Files", value: Double(m.cachedFilesBytes), tint: MetricStyle.memory.shade(3, of: 5)),
         .init(label: "Free", value: Double(m.freeBytes), tint: .secondary)]
    }
}

struct NetworkDetailView: View {
    let metrics: LiveMetrics
    @State private var range: ChartRange = .live

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Network", subtitle: "Throughput, latency and connection health.") { ChartRangePicker(range: $range) }
                Section2(title: "Throughput", subtitle: metrics.network?.interface.map { "Interface \($0)" } ?? "No connection") {
                    Group {
                        if range == .live {
                            TimeSeriesChart(series: [.init(name: "Download", values: metrics.downHistory.values, tint: MetricStyle.network.tint),
                                                     .init(name: "Upload", values: metrics.upHistory.values, tint: MetricStyle.upload.tint)],
                                            interval: metrics.samplingInterval,
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
                                            interval: 5, format: { "\(Int($0)) ms" })
                        } else {
                            HistoryChart(history: metrics.history,
                                         lines: [.init(kind: .latencyMs, name: "Internet", tint: MetricStyle.internet.tint),
                                                 .init(kind: .secondaryLatencyMs, name: "Second target", tint: .cyan),
                                                 .init(kind: .gatewayLatencyMs, name: "Gateway", tint: .orange),
                                                 .init(kind: .dnsLatencyMs, name: "DNS", tint: .purple)],
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
    }

    @ViewBuilder
    private func probeRows(_ title: String, _ probe: ProbeReading?) -> some View {
        if let probe {
            KeyValue(title, probe.address)
            KeyValue("  Latency", probe.latencyMs.map { "\(Int($0.rounded())) ms" } ?? "timeout")
            KeyValue("  Packet loss (1 min)", probe.lossPercent.map(Format.percent) ?? "--")
        }
    }
}

struct StorageView: View {
    let metrics: LiveMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader("Storage", subtitle: "Startup disk capacity.")
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
                PageHeader("Battery", subtitle: "Charge, wear and accessory batteries.")
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
                            KeyValue("Condition", b.condition.map(Format.batteryCondition) ?? "--")
                            KeyValue("Cycle count", b.cycleCount.map(String.init) ?? "--")
                            KeyValue("Maximum capacity", b.maximumCapacityPercent.map(Format.percent) ?? "--")
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
            Text("No Bluetooth accessories reporting a battery level.").foregroundStyle(.secondary)
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

private struct KeyValue: View {
    let key: String
    let value: String
    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
