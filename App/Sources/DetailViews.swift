import SwiftUI
import Charts
import PulseCore
import PulseCollectors
import PulseEngine
import PulseStore

// Section screens for the dashboard (PRD §16). "Live" charts use the in-memory last few minutes;
// other ranges read PulseStore history.

struct PerformanceView: View {
    let metrics: LiveMetrics
    @State private var range: ChartRange = .live

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Performance", subtitle: "CPU, GPU and memory over time.") { ChartRangePicker(range: $range) }
                Section2(title: "CPU", subtitle: metrics.processorName) {
                    Group {
                        if range == .live {
                            TimeSeriesChart(series: [.init(name: "CPU", values: metrics.cpuHistory.values, tint: MetricStyle.cpu.tint)],
                                            interval: metrics.samplingInterval, maximum: 100, format: { "\(Int($0))%" })
                        } else {
                            HistoryChart(history: metrics.history, lines: [.init(kind: .cpuPercent, name: "CPU", tint: MetricStyle.cpu.tint)],
                                         range: range, maximum: 100, format: { "\(Int($0))%" })
                        }
                    }
                    .frame(height: 180)
                    if let cores = metrics.cpu?.perCorePercent {
                        PerCoreBars(values: cores)
                    }
                }
                Section2(title: "GPU", subtitle: metrics.gpu.map { "\(Format.percent($0.utilizationPercent)) now" }) {
                    if range == .live {
                        if let g = metrics.gpu {
                            UsageBar(fraction: g.utilizationPercent / 100, tint: MetricStyle.gpu.tint)
                            if let mem = g.memoryInUseBytes { Text("GPU memory in use: \(Format.memory(mem))").font(.caption).foregroundStyle(.secondary) }
                        } else {
                            Text("No GPU data").foregroundStyle(.secondary)
                        }
                    } else {
                        HistoryChart(history: metrics.history, lines: [.init(kind: .gpuPercent, name: "GPU", tint: MetricStyle.gpu.tint)],
                                     range: range, maximum: 100, format: { "\(Int($0))%" })
                            .frame(height: 140)
                    }
                }
                Section2(title: "Memory", subtitle: metrics.memory.map { "\(Format.memory($0.totalBytes)) installed" }) {
                    Group {
                        if range == .live {
                            TimeSeriesChart(series: [.init(name: "Used", values: metrics.memoryHistory.values, tint: MetricStyle.memory.tint)],
                                            interval: metrics.samplingInterval, maximum: 100, format: { "\(Int($0))%" })
                        } else {
                            HistoryChart(history: metrics.history, lines: [.init(kind: .memoryPercent, name: "Used", tint: MetricStyle.memory.tint)],
                                         range: range, maximum: 100, format: { "\(Int($0))%" })
                        }
                    }
                    .frame(height: 180)
                    if let m = metrics.memory {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            KeyValue("Used", Format.memory(m.usedBytes))
                            KeyValue("App memory", Format.memory(m.appBytes))
                            KeyValue("Wired", Format.memory(m.wiredBytes))
                            KeyValue("Compressed", Format.memory(m.compressedBytes))
                            KeyValue("Swap used", Format.memory(m.swapUsedBytes))
                            KeyValue("Pressure", m.pressure.map { Format.health($0.health) } ?? "Unknown")
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct PerCoreBars: View {
    let values: [Double]

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            BarMark(x: .value("Core", "\(index + 1)"), y: .value("Usage", value))
                .foregroundStyle(MetricStyle.cpu.tint.gradient)
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") } } }
        .frame(height: 110)
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

struct SensorsView: View {
    let metrics: LiveMetrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader("Sensors", subtitle: "Thermal state, temperatures and fans.")
                HStack(spacing: 12) {
                    Text(metrics.thermal.map(Format.thermal) ?? "--").font(.largeTitle.weight(.semibold))
                    if let t = metrics.thermal { HealthBadge(level: t.health) }
                    Spacer()
                }
                Text("macOS thermal state — what drives throttling, alerts and health.")
                    .font(.caption).foregroundStyle(.secondary)

                if let s = metrics.sensors, !s.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        KeyValue("CPU", s.cpuCelsius.map(Format.celsius) ?? "–")
                        KeyValue("SSD", s.ssdCelsius.map(Format.celsius) ?? "–")
                        KeyValue("Battery", s.batteryCelsius.map(Format.celsius) ?? "–")
                        ForEach(s.fans) { fan in
                            KeyValue("Fan \(fan.index + 1)", fan.rpm < 1 ? "Stopped" : "\(Int(fan.rpm.rounded())) rpm"
                                     + (fan.maxRPM.map { " / \(Int($0)) max" } ?? ""))
                        }
                        if let gpu = metrics.gpu { KeyValue("GPU load", Format.percent(gpu.utilizationPercent)) }
                    }
                    DisclosureGroup("All sensors (\(s.sensors.count))") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                            ForEach(s.sensors) { KeyValue($0.name, Format.celsius($0.celsius)) }
                        }
                        .padding(.top, 6)
                    }
                    Text("Temperatures and fans use undocumented macOS interfaces and may be unavailable after a macOS update.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if metrics.sensors != nil {
                    Text("Temperature sensors are not available on this Mac or macOS version.").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                if !metrics.temperatureHistory.values.isEmpty {
                    Sparkline(values: metrics.temperatureHistory.values, tint: MetricStyle.temperature.tint, height: 70)
                }

                Text("Thermal state changes").font(.headline).padding(.top, 8)
                if metrics.thermalChanges.isEmpty {
                    Text("No changes since launch.").foregroundStyle(.secondary)
                } else {
                    ForEach(metrics.thermalChanges.reversed()) { change in
                        HStack {
                            Text(change.date, style: .time).monospacedDigit().foregroundStyle(.secondary)
                            Text(Format.thermal(change.state))
                            Spacer()
                            HealthBadge(level: change.state.health)
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear(perform: metrics.sensorsAppeared)
        .onDisappear(perform: metrics.sensorsDisappeared)
    }
}

// MARK: - Shared pieces

private struct Section2<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SubsectionHeader(title, subtitle: subtitle)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
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
