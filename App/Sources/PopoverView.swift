import SwiftUI
import PulseCore
import PulseCollectors
import PulseEngine

/// PRD §5 Level 2 in the mockup style: five metric rows with sparklines, top processes, open button.
struct PopoverView: View {
    let metrics: LiveMetrics
    let openDashboard: () -> Void
    @Environment(\.openSettings) private var openSettings
    @State private var icons = IconCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                cpuRow
                memoryRow
                networkRow
                if let battery = metrics.battery { batteryRow(battery) }
                temperatureRow
            }
            Divider()
            topProcesses
            Button(action: openDashboard) {
                HStack {
                    Spacer()
                    Text("Open Mac Pulse")
                    Spacer()
                }
                .overlay(alignment: .trailing) { Text("⌘O").foregroundStyle(.secondary) }
                .padding(.vertical, 2)
            }
            .controlSize(.large)
            .keyboardShortcut("o")
        }
        .padding(16)
        .frame(width: 400)
        .background { quitShortcut }
        .onAppear {
            metrics.processListAppeared()
            metrics.sensorsAppeared()
        }
        .onDisappear {
            metrics.processListDisappeared()
            metrics.sensorsDisappeared()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AppLogo(size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Pulse").font(.headline)
                Text("Your Mac at a glance").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Divider()
                Button("Quit Mac Pulse") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings and Quit")
        }
    }

    /// ⌘Q while the popover is key; menu-item shortcuts only fire while the menu is open.
    private var quitShortcut: some View {
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .hidden()
    }

    // MARK: Metric rows

    private var cpuRow: some View {
        MetricRow(style: .cpu, title: "CPU", value: metrics.cpu.map { Format.percent($0.totalPercent) },
                  sparkline: Sparkline(values: metrics.cpuHistory.values, tint: MetricStyle.cpu.tint, domain: 0...100, height: 24)) {
            badge(metrics.cpuHealth)
        }
    }

    private var memoryRow: some View {
        MetricRow(style: .memory, title: "Memory",
                  value: metrics.memory.map { Format.memoryUsage(used: $0.usedBytes, total: $0.totalBytes) },
                  sparkline: Sparkline(values: metrics.memoryHistory.values, tint: MetricStyle.memory.tint, domain: 0...100, height: 24)) {
            badge(metrics.memory?.pressure?.health)
        }
    }

    private var networkRow: some View {
        let n = metrics.network, h = metrics.networkHealth
        return MetricRow(style: .network, title: "Network", value: nil, sparkline: nil) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down").foregroundStyle(MetricStyle.network.tint)
                    Text(n.map { Format.rate($0.downBytesPerSec) } ?? "--")
                }
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up").foregroundStyle(MetricStyle.upload.tint)
                    Text(n.map { Format.rate($0.upBytesPerSec) } ?? "--")
                }
                Spacer(minLength: 4)
                if let h {
                    HealthBadge(level: h.health, label: MenuBarFormatter.latency(h))
                        .help("Internet latency · \(Format.health(h.health))")
                }
            }
            .font(.callout)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    private func batteryRow(_ b: BatteryReading) -> some View {
        MetricRow(style: .battery, title: "Battery", value: Format.percent(b.percent),
                  sparkline: Sparkline(values: metrics.batteryHistory.values, tint: MetricStyle.battery.tint,
                                       points: 120, domain: 0...100, height: 24)) {
            Text(batteryDetail(b)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func batteryDetail(_ b: BatteryReading) -> String {
        guard let minutes = b.minutesRemaining else { return b.isCharging ? "Charging" : (b.onACPower ? "On AC" : "") }
        return b.isCharging ? "\(Format.duration(minutes: minutes)) to full" : "\(Format.duration(minutes: minutes)) left"
    }

    private var temperatureRow: some View {
        let celsius = metrics.sensors?.cpuCelsius
        return MetricRow(style: .temperature, title: "Temperature",
                         value: celsius.map(Format.celsius) ?? metrics.thermal.map(Format.thermal),
                         sparkline: celsius == nil ? nil
                            : Sparkline(values: metrics.temperatureHistory.values, tint: MetricStyle.temperature.tint, height: 24)) {
            badge(metrics.thermal?.health)
        }
    }

    @ViewBuilder
    private func badge(_ level: HealthLevel?) -> some View {
        if let level { HealthBadge(level: level) }
    }

    // MARK: Top processes

    private var topProcesses: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top Processes").font(.headline)
                Spacer()
                Text("CPU").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(metrics.topProcesses(byCPU: 5)) { process in
                HStack(spacing: 8) {
                    Image(nsImage: icons.icon(for: process.pid)).resizable().frame(width: 20, height: 20)
                    Text(process.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Format.decimal(process.cpuPercent, places: 1))%").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Icon · title · value · sparkline · trailing (badge or detail). A nil value lets `trailing` span the value columns.
private struct MetricRow<Trailing: View>: View {
    let style: MetricStyle
    let title: String
    let value: String?
    let sparkline: Sparkline?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        GridRow {
            Image(systemName: style.symbol).foregroundStyle(style.tint).font(.title3).frame(width: 24)
            Text(title).font(.headline).fixedSize()
            if value == nil && sparkline == nil {
                trailing.gridCellColumns(3)
            } else {
                Text(value ?? "--").monospacedDigit().lineLimit(1).fixedSize()
                Group {
                    if let sparkline { sparkline } else { Color.clear.frame(height: 24) }
                }
                .frame(minWidth: 50, maxWidth: 80)
                trailing.fixedSize().gridColumnAlignment(.trailing)
            }
        }
    }
}
