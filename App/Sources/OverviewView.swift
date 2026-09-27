import SwiftUI
import PulseCore
import PulseCollectors
import PulseEngine

/// Mockup Overview: fixed 3-column grid — CPU/Memory/Network, Disk/Battery/Temperature, Internet Health + Recent Activity.
struct OverviewView: View {
    let metrics: LiveMetrics
    let runDiagnostics: () -> Void
    let showTimeline: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Overview", subtitle: "A real-time view of your Mac's health and performance.") {
                    Button(action: runDiagnostics) { Label("Run Diagnostics", systemImage: "waveform.path.ecg") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help("Run Diagnostics (⌘R)")
                }
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        cpuCard
                        memoryCard
                        networkCard
                    }
                    GridRow {
                        diskCard
                        if let battery = metrics.battery {
                            batteryCard(battery)
                            temperatureCard
                        } else {
                            temperatureCard.gridCellColumns(2)
                        }
                    }
                    GridRow {
                        internetCard
                        recentActivity.gridCellColumns(2)
                    }
                }
            }
            .padding(24)
        }
    }

    private var cpuCard: some View {
        MetricCard(title: "CPU", style: .cpu, health: metrics.cpuHealth) {
            BigValue(metrics.cpu.map { Format.percent($0.totalPercent) }, awaiting: "Reading CPU usage…")
            Text(metrics.processorName ?? " ").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Sparkline(values: metrics.cpuHistory.values, tint: MetricStyle.cpu.tint, domain: 0...100)
            FooterStats(stats: [
                .init(label: "Avg (5m)", value: metrics.cpuFiveMinuteAverage.map(Format.percent)),
                .init(label: "Peak (5m)", value: metrics.cpuFiveMinutePeak.map(Format.percent)),
                .init(label: "Cores", value: metrics.cpu.map { "\($0.perCorePercent.count)" }),
            ])
        }
    }

    private var memoryCard: some View {
        let m = metrics.memory
        return MetricCard(title: "Memory", style: .memory, health: m?.pressure?.health) {
            BigValue(m.map { Format.memoryUsage(used: $0.usedBytes, total: $0.totalBytes) }, awaiting: "Reading memory…")
            Text(m.map { "\(Format.percent($0.usedPercent)) in use" } ?? " ").font(.callout).foregroundStyle(.secondary)
            Sparkline(values: metrics.memoryHistory.values, tint: MetricStyle.memory.tint, domain: 0...100)
            FooterStats(stats: [
                .init(label: "App", value: m.map { Format.memory($0.appBytes) }),
                .init(label: "Wired", value: m.map { Format.memory($0.wiredBytes) }),
                .init(label: "Compressed", value: m.map { Format.memory($0.compressedBytes) }),
            ])
        }
    }

    private var networkCard: some View {
        let n = metrics.network, h = metrics.networkHealth
        return MetricCard(title: "Network", style: .network, health: h?.health,
                          healthLabel: h?.connectivity == .offline ? "Offline" : nil) {
            HStack(spacing: 16) {
                if let n {
                    rateLabel(n.downBytesPerSec, arrow: "arrow.down", tint: MetricStyle.network.tint)
                    rateLabel(n.upBytesPerSec, arrow: "arrow.up", tint: MetricStyle.upload.tint)
                } else {
                    Text("Reading throughput…").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(n?.interface.map { "Interface \($0)" } ?? "No connection").font(.callout).foregroundStyle(.secondary)
            Sparkline(series: [
                .init(name: "Download", values: metrics.downHistory.values, tint: MetricStyle.network.tint),
                .init(name: "Upload", values: metrics.upHistory.values, tint: MetricStyle.upload.tint),
            ])
            FooterStats(stats: [
                .init(label: "Download", value: n.map { Format.rate($0.downBytesPerSec) }, dot: MetricStyle.network.tint),
                .init(label: "Upload", value: n.map { Format.rate($0.upBytesPerSec) }, dot: MetricStyle.upload.tint),
                .init(label: "Ping", value: h.map(MenuBarFormatter.latency)),
            ])
        }
    }

    private func rateLabel(_ value: Double, arrow: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(Format.rate(value)).font(.title2.weight(.semibold)).monospacedDigit()
            Image(systemName: arrow).foregroundStyle(tint).font(.headline)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var diskCard: some View {
        MetricCard(title: "Disk", style: .disk) {
            if let d = metrics.disk, d.totalBytes > 0 {
                let fraction = Double(d.usedBytes) / Double(d.totalBytes)
                Text(d.volumeName ?? "Startup disk").font(.title3.weight(.semibold))
                HStack {
                    Text("\(Format.bytesShort(d.usedBytes)) used / \(Format.bytesShort(d.totalBytes))")
                    Spacer()
                    Text(Format.percent(fraction * 100)).monospacedDigit()
                }
                .font(.callout).foregroundStyle(.secondary)
                UsageBar(fraction: fraction, tint: MetricStyle.disk.tint)
                Spacer(minLength: 0)
                FooterStats(stats: [
                    .init(label: "Used", value: Format.bytesShort(d.usedBytes), dot: MetricStyle.disk.tint),
                    .init(label: "Free", value: Format.bytesShort(d.availableBytes), dot: .secondary),
                    .init(label: "Capacity", value: Format.bytesShort(d.totalBytes)),
                ])
            } else {
                Text("No volume is reporting capacity.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func batteryCard(_ b: BatteryReading) -> some View {
        MetricCard(title: "Battery", style: .battery, health: b.condition?.health) {
            BigValue(Format.percent(b.percent))
            Text(batteryLine(b)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Sparkline(values: metrics.batteryHistory.values, tint: MetricStyle.battery.tint, points: 120, domain: 0...100)
            FooterStats(stats: [
                .init(label: "Cycles", value: b.cycleCount.map(String.init)),
                .init(label: "Condition", value: b.condition.map(Format.batteryCondition)),
                .init(label: "Capacity", value: b.maximumCapacityPercent.map(Format.percent)),
            ])
        }
    }

    private func batteryLine(_ b: BatteryReading) -> String {
        guard let minutes = b.minutesRemaining else { return Format.batteryState(b) }
        return b.isCharging ? "\(Format.duration(minutes: minutes)) until full" : "\(Format.duration(minutes: minutes)) remaining"
    }

    /// What the headline figure means. With a °C reading the thermal state qualifies it; without
    /// sensors the figure *is* the thermal state, so the caption names that instead of dashing it.
    private func thermalCaption(_ s: SensorsReading?) -> String {
        guard s?.cpuCelsius != nil else { return "macOS thermal state" }
        return metrics.thermal.map { "CPU · thermal state \(Format.thermal($0))" } ?? "CPU die"
    }

    private var temperatureCard: some View {
        let s = metrics.sensors
        return MetricCard(title: "Temperature", style: .temperature, health: metrics.thermal?.health) {
            BigValue(s?.cpuCelsius.map(Format.celsius) ?? metrics.thermal.map(Format.thermal), awaiting: "Reading temperature…")
            Text(thermalCaption(s))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Sparkline(values: metrics.temperatureHistory.values, tint: MetricStyle.temperature.tint)
            if let s, !s.isEmpty {
                FooterStats(stats: [
                    .init(label: "CPU", value: s.cpuCelsius.map(Format.celsius)),
                    .init(label: "SSD", value: s.ssdCelsius.map(Format.celsius)),
                    .init(label: "Battery", value: s.batteryCelsius.map(Format.celsius)),
                    .init(label: "Fan rpm", value: s.fans.max(by: { $0.rpm < $1.rpm }).map { $0.rpm < 1 ? "Off" : "\(Int($0.rpm.rounded()))" }),
                ])
            }
        }
    }

    private var internetCard: some View {
        let h = metrics.networkHealth
        return MetricCard(title: "Internet Health", style: .internet, health: h?.health,
                          healthLabel: h?.connectivity == .offline ? "Offline" : nil) {
            Text(internetMessage(h)).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Divider()
            HStack(alignment: .top) {
                if let latency = h.map(MenuBarFormatter.latency) {
                    internetStat(value: latency, label: "Ping",
                                 icon: "circle.fill", tint: h?.health.markTint ?? .secondary)
                }
                Divider()
                if let down = metrics.network.map({ Format.rate($0.downBytesPerSec) }) {
                    internetStat(value: down, label: "Download",
                                 icon: "arrow.down", tint: MetricStyle.network.tint)
                }
                Divider()
                if let up = metrics.network.map({ Format.rate($0.upBytesPerSec) }) {
                    internetStat(value: up, label: "Upload",
                                 icon: "arrow.up", tint: MetricStyle.upload.tint)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Three stats share a third of the Overview grid, so at the 980pt window minimum the roomy
    /// variant does not fit. Rather than shrink the figure toward illegibility, drop to a smaller
    /// type step — the reading stays whole either way.
    private func internetStat(value: String, label: String, icon: String, tint: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            internetStat(value: value, label: label, icon: icon, tint: tint, font: .title3)
            internetStat(value: value, label: label, icon: icon, tint: tint, font: .callout)
        }
    }

    private func internetStat(value: String, label: String, icon: String, tint: Color,
                              font: Font) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(tint).font(icon == "circle.fill" ? .system(size: 8) : .callout)
                Text(value).font(font.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize()
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func internetMessage(_ h: NetworkHealthReading?) -> String {
        guard let h else { return "Checking your connection…" }
        if h.connectivity == .offline { return "This Mac is offline." }
        switch h.health {
        case .healthy: return "Your connection looks good."
        case .warning: return "Your connection is slower than usual."
        case .critical: return "Your connection has serious problems."
        case .unknown: return "Checking your connection…"
        }
    }

    /// Mockup "Recent Activity": latest events since launch; "View All" opens the Timeline.
    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: MetricStyle.timeline.symbol).foregroundStyle(.secondary).font(.title3).frame(width: 24)
                Text("Recent Activity").font(.headline)
                Spacer()
                Button("View All", action: showTimeline).controlSize(.small)
            }
            let latest = Array(metrics.recentEvents.suffix(5).reversed())
            if latest.isEmpty {
                Text("Nothing notable yet.").foregroundStyle(.secondary)
            } else {
                ForEach(latest) { EventRow(event: $0).font(.callout) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

/// Rounded usage bar (mockup disk bar).
struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("Used")
        .accessibilityValue(Format.percent(fraction * 100))
    }
}
