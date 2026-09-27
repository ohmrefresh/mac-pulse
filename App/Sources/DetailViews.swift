import SwiftUI
import Charts
import PulseCore
import PulseCollectors
import PulseEngine

// Section screens for the dashboard (PRD §16). History here is the in-memory last few minutes;
// longer ranges arrive with PulseStore in v1.0.

struct PerformanceView: View {
    let metrics: LiveMetrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Section2(title: "CPU", subtitle: metrics.processorName) {
                    TimeSeriesChart(series: [.init(name: "CPU", values: metrics.cpuHistory.values)],
                                    interval: metrics.samplingInterval, maximum: 100, format: { "\(Int($0))%" })
                        .frame(height: 180)
                    if let cores = metrics.cpu?.perCorePercent {
                        PerCoreBars(values: cores)
                    }
                }
                Section2(title: "Memory", subtitle: metrics.memory.map { "\(Format.memory($0.totalBytes)) installed" }) {
                    TimeSeriesChart(series: [.init(name: "Used", values: metrics.memoryHistory.values)],
                                    interval: metrics.samplingInterval, maximum: 100, format: { "\(Int($0))%" })
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
            .padding(20)
        }
        .navigationTitle("Performance")
    }
}

private struct PerCoreBars: View {
    let values: [Double]

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            BarMark(x: .value("Core", "\(index + 1)"), y: .value("Usage", value))
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") } } }
        .frame(height: 110)
    }
}

struct NetworkDetailView: View {
    let metrics: LiveMetrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Section2(title: "Throughput", subtitle: metrics.network?.interface.map { "Interface \($0)" } ?? "No connection") {
                    TimeSeriesChart(series: [.init(name: "Download", values: metrics.downHistory.values),
                                             .init(name: "Upload", values: metrics.upHistory.values)],
                                    interval: metrics.samplingInterval,
                                    format: { MenuBarFormatter.rate($0) + "/s" })
                        .frame(height: 180)
                }
                Section2(title: "Internet latency", subtitle: "Probe every 5 s · gaps are timeouts") {
                    TimeSeriesChart(series: [.init(name: "Latency", values: metrics.latencyHistory.values)],
                                    interval: 5, format: { "\(Int($0)) ms" })
                        .frame(height: 160)
                    if let h = metrics.networkHealth {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            GridRow {
                                Text("Status").foregroundStyle(.secondary)
                                HealthBadge(level: h.health, label: h.connectivity == .offline ? "Offline" : nil)
                            }
                            probeRows("Internet", h.internet)
                            probeRows("Gateway", h.gateway)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Network")
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
        Group {
            if let d = metrics.disk {
                VStack(alignment: .leading, spacing: 16) {
                    Text(d.volumeName ?? "Startup disk").font(.title3.weight(.semibold))
                    ProgressView(value: Double(d.usedBytes), total: Double(max(d.totalBytes, 1)))
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        KeyValue("Capacity", Format.bytes(d.totalBytes))
                        KeyValue("Used", Format.bytes(d.usedBytes))
                        KeyValue("Available", Format.bytes(d.availableBytes))
                    }
                    Text("Available includes purgeable space, matching Finder. Refreshed every 60 s.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(20)
            } else {
                ContentUnavailableView("No disk data yet", systemImage: "internaldrive")
            }
        }
        .navigationTitle("Storage")
    }
}

struct BatteryView: View {
    let metrics: LiveMetrics

    var body: some View {
        Group {
            if let b = metrics.battery {
                VStack(alignment: .leading, spacing: 16) {
                    Text(Format.percent(b.percent)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                    ProgressView(value: b.percent, total: 100)
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        KeyValue("State", Format.batteryState(b))
                        KeyValue("Cycle count", b.cycleCount.map(String.init) ?? "--")
                        KeyValue("Maximum capacity", b.maximumCapacityPercent.map(Format.percent) ?? "--")
                    }
                    Spacer()
                }
                .padding(20)
            } else {
                ContentUnavailableView("No battery", systemImage: "battery.0percent",
                                       description: Text("This Mac has no internal battery."))
            }
        }
        .navigationTitle("Battery")
    }
}

struct SensorsView: View {
    let metrics: LiveMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(metrics.thermal.map(Format.thermal) ?? "--").font(.largeTitle.weight(.semibold))
                if let t = metrics.thermal { HealthBadge(level: t.health) }
            }
            Text("macOS thermal state. Temperature readings in °C are planned for a later release.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Recent changes").font(.headline).padding(.top, 8)
            if metrics.thermalChanges.isEmpty {
                Text("No changes since launch.").foregroundStyle(.secondary)
            } else {
                List(metrics.thermalChanges.reversed()) { change in
                    HStack {
                        Text(change.date, style: .time).monospacedDigit().foregroundStyle(.secondary)
                        Text(Format.thermal(change.state))
                        Spacer()
                        HealthBadge(level: change.state.health)
                    }
                }
                .listStyle(.inset)
            }
            Spacer()
        }
        .padding(20)
        .navigationTitle("Sensors")
    }
}

// MARK: - Shared pieces

private struct Section2<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            content
        }
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
