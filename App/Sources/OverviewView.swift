import SwiftUI
import PulseCore
import PulseCollectors
import PulseEngine

/// After `docs/prd/Redesign_v1.html`: the Concern, then CPU / Memory / Network as headline cards,
/// Disk / Battery / Thermal as compact tiles, and the busiest processes beside Recent Activity.
struct OverviewView: View {
    let metrics: LiveMetrics
    let runDiagnostics: () -> Void
    let showProcesses: (ProcessSort) -> Void
    let showTimeline: (TimelineCategory?) -> Void
    @AppStorage("overviewProcessSort") private var processSort = ProcessSort.cpu

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let concern = metrics.concern { banner(concern) }
                WeightedHStack {
                    cpuCard
                    memoryCard
                    networkCard
                }
                WeightedHStack {
                    diskTile
                    if let battery = metrics.battery { batteryTile(battery) }
                    thermalTile
                }
                WeightedHStack(weights: [5, 7]) {
                    topProcesses
                    recentActivity
                }
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: runDiagnostics) { Label("Run Diagnostics", systemImage: "waveform.path.ecg") }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .help("Run Diagnostics (⌘R)")
            }
        }
        // The Top processes card and the CPU card's busiest process want the 1 s scan.
        .onAppear(perform: metrics.processListAppeared)
        .onDisappear(perform: metrics.processListDisappeared)
    }

    // MARK: Concern

    private func banner(_ concern: Concern) -> some View {
        ConcernBanner(concern: concern, metrics: metrics, prominent: true) {
            HStack(spacing: 8) {
                switch concern.signal {
                case .cpu: Button("Show Processes") { showProcesses(.cpu) }
                case .memory: Button("Show Processes") { showProcesses(.memory) }
                default: EmptyView()
                }
                Button("View Timeline") { showTimeline(concern.signal.category) }
            }
            .fixedSize()
        }
    }

    // MARK: Headline cards

    private var cpuCard: some View {
        let cpu = metrics.cpu
        let detail = [metrics.processorName, cpu.map { "\($0.perCorePercent.count) cores" }]
            .compactMap { $0 }.joined(separator: " · ")
        let top = metrics.topProcesses(byCPU: 1).first
        return MetricCard(title: "CPU", style: .cpu, health: metrics.cpuHealth, emphasizesHealth: true) {
            headline(detail: detail) {
                if let cpu {
                    figure("\(Int(cpu.totalPercent.rounded()))", unit: "%", health: metrics.cpuHealth)
                } else {
                    BigValue(nil, awaiting: "Reading CPU usage…")
                }
            }
            Sparkline(values: metrics.cpuHistory.values, tint: MetricStyle.cpu.tint, domain: 0...100)
            Divider()
            FooterStats(stats: [
                .init(label: "Avg 5m", value: metrics.cpuFiveMinuteAverage.map(Format.percent)),
                .init(label: "Peak 5m", value: metrics.cpuFiveMinutePeak.map(Format.percent)),
                .init(label: "Top", value: top.map { "\($0.name) · \(Format.decimal($0.cpuPercent, places: 0))%" }),
            ])
        }
    }

    private var memoryCard: some View {
        let m = metrics.memory
        let health = m?.pressure?.health
        let parts: [(String, UInt64)] = m.map { [("App", $0.appBytes), ("Wired", $0.wiredBytes),
                                                 ("Compressed", $0.compressedBytes)] } ?? []
        let total = Double(max(m?.totalBytes ?? 0, 1))
        let shades = (0..<3).map { MetricStyle.memory.shade($0, of: 3) }
        return MetricCard(title: "Memory", style: .memory, health: health, emphasizesHealth: true) {
            headline(detail: m.map { "\(Format.memoryUsage(used: $0.usedBytes, total: $0.totalBytes)) in use" }) {
                if let m {
                    figure("\(Int(m.usedPercent.rounded()))", unit: "%", health: health)
                } else {
                    BigValue(nil, awaiting: "Reading memory…")
                }
            }
            // Memory Used, part by part; the empty track is Cached Files plus Free Memory.
            // Same height as the other cards' sparklines, so all three footers line up.
            StackedMeter(segments: parts.enumerated().map { .init(fraction: Double($1.1) / total, tint: shades[$0]) },
                         height: 12)
                .frame(height: 50)
            Divider()
            FooterStats(stats: parts.enumerated().map { index, part in
                .init(label: part.0, value: Format.memory(part.1), dot: shades[index])
            })
        }
    }

    private var networkCard: some View {
        let n = metrics.network, h = metrics.networkHealth
        let offline = h?.connectivity == .offline
        let link = [n?.interfaceKind, n?.interface].compactMap { $0 }.joined(separator: " ")
        let detail = [link.isEmpty ? nil : link, h?.internet.map { "ping \($0.address)" }]
            .compactMap { $0 }.joined(separator: " · ")
        return MetricCard(title: "Network", style: .network, health: h?.health,
                          healthLabel: offline ? "Offline" : nil, emphasizesHealth: true) {
            headline(detail: detail) {
                // Never a guessed latency: offline and timed-out probes read as words.
                if offline {
                    word("Offline", health: h?.health)
                } else if let latency = h?.internet?.latencyMs {
                    figure("\(Int(latency.rounded()))", unit: "ms", health: h?.health)
                } else if h?.internet != nil {
                    word("Timed out", health: h?.health)
                } else {
                    BigValue(nil, awaiting: "Measuring latency…")
                }
            }
            Sparkline(series: [.init(name: "Down", values: metrics.downHistory.values, tint: MetricStyle.network.tint),
                               .init(name: "Up", values: metrics.upHistory.values, tint: MetricStyle.upload.tint)])
            Divider()
            FooterStats(stats: [
                .init(label: "Down", value: n.map { Format.rate($0.downBytesPerSec) }, dot: MetricStyle.network.tint),
                .init(label: "Up", value: n.map { Format.rate($0.upBytesPerSec) }, dot: MetricStyle.upload.tint),
                .init(label: "Packet loss", value: h?.internet?.lossPercent.map(Format.percent)),
            ])
        }
    }

    /// Figure and what it is of, on one baseline.
    private func headline<Figure: View>(detail: String?, @ViewBuilder figure: () -> Figure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            figure()
            if let detail, !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func figure(_ number: String, unit: String, health: HealthLevel?) -> some View {
        FigureText(number: number, unit: unit, size: .title, unitSize: .title3)
            .foregroundStyle(ink(health))
    }

    private func word(_ text: String, health: HealthLevel?) -> some View {
        Text(text).font(.title.weight(.semibold)).lineLimit(1).fixedSize().foregroundStyle(ink(health))
    }

    /// A card washed in its Health Level's tint writes its figure in that level's readable ink.
    private func ink(_ health: HealthLevel?) -> Color {
        guard let health, health >= .warning else { return .primary }
        return health.tint.readableInk(on: .tintedFill(MetricCard<EmptyView>.emphasisFill), minimum: 4.5)
    }

    // MARK: Tiles

    private var diskTile: some View {
        let d = metrics.disk
        return OverviewTile(title: d?.volumeName ?? "Startup disk", style: .disk) {
            if let d, d.totalBytes > 0 {
                Text("\(Format.bytesShort(d.usedBytes)) / \(Format.bytesShort(d.totalBytes))")
            }
        } content: {
            if let d, d.totalBytes > 0 {
                let fraction = Double(d.usedBytes) / Double(d.totalBytes)
                MeterBar(fraction: fraction, tint: MetricStyle.disk.tint)
                Text("\(Format.bytesShort(d.availableBytes)) free · \(Format.percent(fraction * 100)) used")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No volume reporting capacity.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func batteryTile(_ b: BatteryReading) -> some View {
        let state = b.isCharging ? "Charging" : (b.onACPower ? "On AC" : "On battery")
        let remaining = b.minutesRemaining.map {
            b.isCharging ? "\(Format.duration(minutes: $0)) to full" : "\(Format.duration(minutes: $0)) left"
        }
        let detail = [remaining, b.cycleCount.map { "\($0) cycles" },
                      b.condition.map { "Condition \(Format.batteryCondition($0).lowercased())" },
                      b.maximumCapacityPercent.map { "Capacity \(Format.percent($0))" }]
            .compactMap { $0 }.joined(separator: " · ")
        let condition = b.condition?.health
        return OverviewTile(title: "Battery", style: .battery) {
            Label("\(state) · \(Format.percent(b.percent))",
                  systemImage: b.onACPower ? "bolt.fill" : "battery.50percent")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(condition.map { $0 >= .warning } == true
                                 ? condition!.tint.readableInk(on: .card, minimum: 4.5) : Color.secondary)
        } content: {
            MeterBar(fraction: b.percent / 100, tint: MetricStyle.battery.tint)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private var thermalTile: some View {
        let s = metrics.sensors
        let fan = s?.fans.map(\.rpm).max()
        // Each column only when this Mac reports it (ADR 0002 fail-soft); none at all hides the row.
        let columns: [(String, String?)] = [
            ("CPU", s?.cpuCelsius.map(Format.celsius)),
            ("SSD", s?.ssdCelsius.map(Format.celsius)),
            ("Battery", s?.batteryCelsius.map(Format.celsius)),
            ("Fan", fan.map { $0 < 1 ? "Stopped" : "\(Format.decimal($0, places: 0)) rpm" }),
        ].filter { $0.1 != nil }
        return OverviewTile(title: "Thermal", style: .temperature) {
            if let t = metrics.thermal {
                Text(Format.thermal(t)).foregroundStyle(t.health.tint.readableInk(on: .card, minimum: 4.5))
            }
        } content: {
            if columns.isEmpty {
                Text("Thermal state from macOS; no temperature sensors to read.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                HStack(spacing: 16) {
                    ForEach(columns, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label).font(.caption).foregroundStyle(.secondary)
                            Text(value ?? "").font(.callout.weight(.semibold)).monospacedDigit()
                        }
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Processes and activity

    private var topProcesses: some View {
        VStack(alignment: .leading, spacing: 10) {
            TopProcessList(metrics: metrics, sort: $processSort, count: 6)
            Spacer(minLength: 0)
            Button("All \(metrics.processes.count) processes →") { showProcesses(processSort) }
                .buttonStyle(.link)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }

    /// The latest Timeline Events, newest first; "View All" opens the Timeline.
    private var recentActivity: some View {
        let latest = Array(metrics.recentEvents.suffix(5).reversed())
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent Activity").font(.headline)
                Spacer()
                Button("View All") { showTimeline(nil) }.buttonStyle(.link).font(.callout)
            }
            .padding(.bottom, 4)
            if latest.isEmpty {
                Text("Nothing notable yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(latest.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider() }
                    ActivityRow(event: event)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

/// Icon · title with a trailing figure · a bar or figures below. Row 2 of the Overview.
private struct OverviewTile<Trailing: View, Content: View>: View {
    let title: String
    let style: MetricStyle
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: style.symbol).foregroundStyle(style.tint).font(.title3).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    trailing.font(.callout).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardBackground(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

/// Time · severity and title · detail, in the design's columns.
private struct ActivityRow: View {
    let event: TimelineEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(event.time, format: .dateTime.hour().minute())
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    SeverityMark(level: event.severity, font: .caption2)
                    Text(event.title).fontWeight(.medium).lineLimit(1)
                }
                if let detail = event.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
