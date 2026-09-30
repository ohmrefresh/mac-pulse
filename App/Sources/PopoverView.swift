import SwiftUI
import PulseCore
import PulseCollectors
import PulseEngine

/// PRD §5 Level 2, after `docs/prd/Redesign_v1.html`: the Concern first, then one row per metric
/// (name and detail, trend, figure and Health Level), the busiest processes, and uptime.
struct PopoverView: View {
    let metrics: LiveMetrics
    let openDashboard: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.temperatureUnit) private var temperatureUnit
    @AppStorage("popoverProcessSort") private var processSort = ProcessSort.cpu

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let concern = metrics.concern { ConcernBanner(concern: concern, metrics: metrics) }
            VStack(spacing: 10) {
                cpuRow
                Divider()
                memoryRow
                Divider()
                networkRow
                if let battery = metrics.battery {
                    Divider()
                    batteryRow(battery)
                }
                Divider()
                thermalRow
            }
            Divider()
            TopProcessList(metrics: metrics, sort: $processSort)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            metrics.processListAppeared()
            metrics.sensorsAppeared()
        }
        .onDisappear {
            metrics.processListDisappeared()
            metrics.sensorsDisappeared()
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            AppLogo(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Pulse").font(.headline)
                // Polls the unobserved timestamp, so only this line redraws while the popover is open.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.freshness(metrics.lastSampleAt, now: context.date, interval: metrics.samplingInterval))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: openDashboard) {
                HStack(spacing: 6) {
                    Text("Open")
                    Text("⌘O").foregroundStyle(.secondary)
                }
            }
            .keyboardShortcut("o")
            .help("Open Mac Pulse")
            Button {
                NSApp.activate()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var footer: some View {
        HStack {
            if let uptime = metrics.uptime {
                Text("Uptime \(Format.uptime(uptime))")
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Text("Quit")
                    Text("⌘Q").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Metric rows

    private var cpuRow: some View {
        PopoverRow(style: .cpu, title: "CPU",
                   subtitle: metrics.cpu.map { "\($0.perCorePercent.count) cores" }) {
            Sparkline(values: metrics.cpuHistory.values, tint: MetricStyle.cpu.tint, domain: 0...100, height: 26)
        } value: {
            if let cpu = metrics.cpu { FigureText(number: "\(Int(cpu.totalPercent.rounded()))", unit: "%") }
        } status: {
            if let h = metrics.cpuHealth { HealthStatus(level: h) }
        }
    }

    private var memoryRow: some View {
        let m = metrics.memory
        return PopoverRow(style: .memory, title: "Memory",
                          subtitle: m.flatMap { $0.swapUsedBytes > 0 ? "\(Format.gigabytes($0.swapUsedBytes, places: 1)) GB swap" : nil }) {
            MeterBar(fraction: m.map { $0.usedPercent / 100 } ?? 0, tint: MetricStyle.memory.tint)
        } value: {
            if let m {
                FigureText(number: Format.gigabytes(m.usedBytes, places: 1),
                           unit: "/ \(Format.gigabytes(m.totalBytes, places: 0)) GB")
            }
        } status: {
            if let h = m?.pressure?.health { HealthStatus(level: h) }
        }
    }

    private var networkRow: some View {
        let n = metrics.network, h = metrics.networkHealth
        let latency = h?.internet?.latencyMs.map { "\(Int($0.rounded())) ms" }
        let subtitle = [n?.interfaceKind, latency].compactMap { $0 }.joined(separator: " · ")
        return PopoverRow(style: .network, title: "Network", subtitle: subtitle.isEmpty ? nil : subtitle) {
            Sparkline(series: [.init(name: "Down", values: metrics.downHistory.values, tint: MetricStyle.network.tint),
                               .init(name: "Up", values: metrics.upHistory.values, tint: MetricStyle.upload.tint)],
                      height: 26)
        } value: {
            // Throughput appears once the first delta exists.
            if let n {
                HStack(spacing: 8) {
                    rate(n.downBytesPerSec, arrow: "arrow.down", tint: MetricStyle.network.tint)
                    rate(n.upBytesPerSec, arrow: "arrow.up", tint: MetricStyle.upload.tint)
                }
            }
        } status: {
            if let h { HealthStatus(level: h.health, label: h.connectivity == .offline ? "Offline" : nil) }
        }
    }

    private func rate(_ bytesPerSecond: Double, arrow: String, tint: Color) -> some View {
        // "8 KB/s" → figure "8", unit "KB/s", so the number carries the weight like every other row.
        let text = Format.rate(bytesPerSecond)
        let split = text.lastIndex(of: " ") ?? text.endIndex
        return HStack(spacing: 2) {
            Image(systemName: arrow).font(.caption).foregroundStyle(tint)
            FigureText(number: String(text[..<split]), unit: String(text[split...]).trimmingCharacters(in: .whitespaces),
                       size: .callout)
        }
    }

    private func batteryRow(_ b: BatteryReading) -> some View {
        PopoverRow(style: .battery, title: "Battery", subtitle: batteryDetail(b)) {
            MeterBar(fraction: b.percent / 100, tint: MetricStyle.battery.tint)
        } value: {
            FigureText(number: "\(Int(b.percent.rounded()))", unit: "%")
        } status: {
            if b.condition == .serviceRecommended {
                HealthStatus(level: .warning, label: Format.batteryCondition(.serviceRecommended))
            } else {
                Label(b.onACPower ? "On AC" : "Battery", systemImage: b.onACPower ? "bolt.fill" : "battery.50percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private func batteryDetail(_ b: BatteryReading) -> String {
        if let minutes = b.minutesRemaining {
            return b.isCharging ? "\(Format.duration(minutes: minutes)) to full" : "\(Format.duration(minutes: minutes)) left"
        }
        if b.isCharging { return "Charging" }
        return b.onACPower ? "Charged" : "On battery"
    }

    private var thermalRow: some View {
        let celsius = metrics.sensors?.cpuCelsius
        return PopoverRow(style: .temperature, title: "Thermal", subtitle: metrics.sensors.flatMap { Format.fans($0.fans) }) {
            Sparkline(values: metrics.temperatureHistory.values, tint: MetricStyle.temperature.tint, height: 26)
        } value: {
            if let celsius {
                let figure = Format.temperatureFigure(celsius, temperatureUnit)
                FigureText(number: figure.number, unit: figure.unit)
            } else if let t = metrics.thermal {
                // No °C on this Mac: the Thermal State itself is the reading.
                FigureText(number: Format.thermal(t), unit: nil, size: .title3)
            }
        } status: {
            if let h = metrics.thermal?.health { HealthStatus(level: h) }
        }
    }
}

/// Glyph · name and detail · trend or meter · figure over Health Level.
private struct PopoverRow<Chart: View, Value: View, Status: View>: View {
    let style: MetricStyle
    let title: String
    let subtitle: String?
    @ViewBuilder let chart: Chart
    @ViewBuilder let value: Value
    @ViewBuilder let status: Status

    var body: some View {
        // Fixed side columns, so every row's trend starts and ends at the same x.
        HStack(spacing: 12) {
            Image(systemName: style.symbol).foregroundStyle(style.tint).font(.title3).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 96, alignment: .leading)
            chart.frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 2) {
                value
                status
            }
            .frame(minWidth: 92, alignment: .trailing)
        }
        // One utterance per metric: glyph, trend and meter say nothing aloud on their own.
        .accessibilityElement(children: .combine)
    }
}
