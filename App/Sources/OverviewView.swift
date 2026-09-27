import SwiftUI
import Charts
import PulseCore
import PulseCollectors
import PulseEngine

struct OverviewView: View {
    let metrics: LiveMetrics

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                cpuCard
                memoryCard
                networkCard
                internetCard
                diskCard
                if let battery = metrics.battery { batteryCard(battery) }
                thermalCard
            }
            .padding(20)
            recentActivity
                .padding([.horizontal, .bottom], 20)
        }
        .navigationTitle("Overview")
    }

    private var cpuCard: some View {
        Card(title: "CPU", symbol: "cpu", health: nil) {
            BigValue(metrics.cpu.map { Format.percent($0.totalPercent) })
            Text(metrics.processorName ?? "").font(.caption).foregroundStyle(.secondary)
            Sparkline(values: metrics.cpuHistory.suffix(60), maximum: 100)
            Detail("5-min avg", metrics.cpuFiveMinuteAverage.map(Format.percent))
            Detail("Cores", metrics.cpu.map { "\($0.perCorePercent.count)" })
        }
    }

    private var memoryCard: some View {
        Card(title: "Memory", symbol: "memorychip", health: metrics.memory?.pressure?.health) {
            BigValue(metrics.memory.map { "\(Format.memory($0.usedBytes)) / \(Format.memory($0.totalBytes))" })
            Sparkline(values: metrics.memoryHistory.suffix(60), maximum: 100)
            if let m = metrics.memory {
                Detail("App", Format.memory(m.appBytes))
                Detail("Wired", Format.memory(m.wiredBytes))
                Detail("Compressed", Format.memory(m.compressedBytes))
                Detail("Swap", Format.memory(m.swapUsedBytes))
            }
        }
    }

    private var networkCard: some View {
        Card(title: "Network", symbol: "arrow.up.arrow.down", health: nil) {
            BigValue(metrics.network.map {
                "↓\(MenuBarFormatter.rate($0.downBytesPerSec))  ↑\(MenuBarFormatter.rate($0.upBytesPerSec))"
            })
            Sparkline(values: metrics.downHistory.suffix(60), maximum: nil)
            Detail("Interface", metrics.network?.interface ?? "None")
        }
    }

    private var internetCard: some View {
        let health = metrics.networkHealth
        return Card(title: "Internet", symbol: "globe", health: health?.health,
                    healthLabel: health?.connectivity == .offline ? "Offline" : nil) {
            BigValue(health.map(MenuBarFormatter.latency))
            Detail("Target", health?.internet?.address)
            Detail("Packet loss", health?.internet?.lossPercent.map(Format.percent))
            Detail("Gateway", health?.gateway.map { g in
                g.latencyMs.map { "\(g.address) · \(Int($0.rounded()))ms" } ?? "\(g.address) · timeout"
            })
        }
    }

    private var diskCard: some View {
        Card(title: "Disk", symbol: "internaldrive", health: nil) {
            BigValue(metrics.disk.map { Format.bytes($0.availableBytes) + " free" })
            if let d = metrics.disk, d.totalBytes > 0 {
                ProgressView(value: Double(d.usedBytes), total: Double(d.totalBytes))
                Detail("Volume", d.volumeName)
                Detail("Used", "\(Format.bytes(d.usedBytes)) of \(Format.bytes(d.totalBytes))")
            }
        }
    }

    private func batteryCard(_ b: BatteryReading) -> some View {
        Card(title: "Battery", symbol: "battery.75percent", health: nil) {
            BigValue(Format.percent(b.percent))
            Text(Format.batteryState(b)).font(.caption).foregroundStyle(.secondary)
            Detail("Cycle count", b.cycleCount.map(String.init))
            Detail("Max capacity", b.maximumCapacityPercent.map(Format.percent))
        }
    }

    /// Mockup "Recent Activity": latest events since launch; the Timeline section has full history.
    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recent Activity", systemImage: "clock").font(.headline)
            let latest = Array(metrics.recentEvents.suffix(6).reversed())
            if latest.isEmpty {
                Text("Nothing notable yet.").foregroundStyle(.secondary)
            } else {
                ForEach(latest) { EventRow(event: $0) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var thermalCard: some View {
        Card(title: "Thermal", symbol: "thermometer.medium", health: metrics.thermal?.health) {
            BigValue(metrics.thermal.map(Format.thermal))
            Text("macOS thermal state").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let health: HealthLevel?
    var healthLabel: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                if let health { HealthBadge(level: health, label: healthLabel) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct BigValue: View {
    let text: String?
    init(_ text: String?) { self.text = text }

    var body: some View {
        Text(text ?? "--").font(.title2.weight(.semibold)).monospacedDigit()
    }
}

private struct Detail: View {
    let title: String
    let value: String?
    init(_ title: String, _ value: String?) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "--").monospacedDigit()
        }
        .font(.callout)
    }
}

private struct Sparkline: View {
    let values: [Double]
    /// Fixed top of the y-axis (e.g. 100 for percentages); nil scales to the data.
    let maximum: Double?

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("t", point.offset), y: .value("v", point.element))
                .foregroundStyle(.tint.opacity(0.2))
            LineMark(x: .value("t", point.offset), y: .value("v", point.element))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...59)
        .chartYScale(domain: 0...(maximum ?? max(values.max() ?? 1, 1)))
        .frame(height: 40)
    }
}
