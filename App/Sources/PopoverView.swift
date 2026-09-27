import SwiftUI
import PulseCore
import PulseCollectors
import PulseEngine

struct PopoverView: View {
    let metrics: LiveMetrics
    let openDashboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mac Pulse").font(.headline)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("CPU", metrics.cpu.map { Format.percent($0.totalPercent) }, metrics.processorName)
                row("Memory", metrics.memory.map { Format.percent($0.usedPercent) }, memoryDetail)
                row("Network", networkRates, metrics.network?.interface ?? "No connection")
                row("Internet", metrics.networkHealth.map(MenuBarFormatter.latency), internetDetail)
                row("Disk", metrics.disk.map { Format.bytes($0.availableBytes) + " free" },
                    metrics.disk.map { "of " + Format.bytes($0.totalBytes) })
                if let battery = metrics.battery {
                    row("Battery", Format.percent(battery.percent), Format.batteryState(battery))
                }
                row("Thermal", metrics.thermal.map(Format.thermal), metrics.thermal.map { Format.health($0.health) })
            }
            Divider()
            Text("Top Processes").font(.subheadline).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(metrics.topProcesses(byCPU: 5)) { process in
                    GridRow {
                        Text(process.name).lineLimit(1).truncationMode(.middle)
                        Text(String(format: "%.1f%%", process.cpuPercent))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Mac Pulse", action: openDashboard).keyboardShortcut("o")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear(perform: metrics.processListAppeared)
        .onDisappear(perform: metrics.processListDisappeared)
    }

    private func row(_ title: String, _ value: String?, _ detail: String?) -> some View {
        GridRow {
            Text(title)
            Text(value ?? "--").monospacedDigit()
            Text(detail ?? "").foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var networkRates: String? {
        metrics.network.map { "↓\(MenuBarFormatter.rate($0.downBytesPerSec)) ↑\(MenuBarFormatter.rate($0.upBytesPerSec))" }
    }

    private var internetDetail: String? {
        guard let health = metrics.networkHealth else { return nil }
        var parts = [Format.health(health.health)]
        if let loss = health.internet?.lossPercent { parts.append("\(Int(loss.rounded()))% loss") }
        if let gateway = health.gateway?.latencyMs { parts.append("gateway \(Int(gateway.rounded()))ms") }
        return parts.joined(separator: " · ")
    }

    private var memoryDetail: String? {
        guard let memory = metrics.memory else { return nil }
        let pressure = memory.pressure.map { Format.health($0.health) } ?? Format.health(.unknown)
        return "\(Format.memory(memory.usedBytes)) / \(Format.memory(memory.totalBytes)) · \(pressure)"
    }
}
