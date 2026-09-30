import SwiftUI
import PulseCore
import PulseCollectors
import PulseEngine

/// The Network page after `docs/prd/Redesign_v1.html`: a live KPI strip, mirrored throughput,
/// latency against the Health Level bands, and the probe path from gateway to internet. The strip
/// and the Path card always cover the live five minutes; only the two charts follow the range.
struct NetworkDetailView: View {
    let metrics: LiveMetrics
    @State private var range: ChartRange = .live
    @State private var scale: ChartScale = .signedLog
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsView.tabKey) private var settingsTab = SettingsView.Tab.general.rawValue

    private enum Anchor: Hashable { case latency }

    /// Four probes of one metric family: step the family's own tint. A second hue here reads
    /// as a second metric, and orange and purple already mean Temperature and Memory.
    /// Computed, so each render builds new (never-equal) tints — the chart keys by kind.
    static var latencyLines: [HistoryChart.Line] { latencyLines(targets: ProbeTargets.defaults) }

    /// History keeps two target slots — the Primary Target and the first comparison — named after
    /// whatever holds them now. The second slot's line is dropped when there is no comparison.
    static func latencyLines(targets: [ProbeTarget]) -> [HistoryChart.Line] {
        func name(_ t: ProbeTarget) -> String {
            "Internet · " + Format.targetName(label: t.label, address: t.address, host: nil)
        }
        var lines: [HistoryChart.Line] = []
        if let primary = targets.first {
            lines.append(.init(kind: .latencyMs, name: name(primary), tint: pathTint(0)))
        }
        if targets.count > 1 {
            lines.append(.init(kind: .secondaryLatencyMs, name: name(targets[1]), tint: pathTint(1)))
        }
        lines.append(.init(kind: .gatewayLatencyMs, name: "Gateway", tint: pathTint(2)))
        lines.append(.init(kind: .dnsLatencyMs, name: "DNS", tint: pathTint(3)))
        return lines
    }

    /// One family, one hue, stepped per probe: the Primary Target, its comparisons, gateway and DNS
    /// keep the same shade on the Path card and in the stored-range chart. Slots 4 and 5 are the
    /// third and fourth targets, which history does not keep.
    static func pathTint(_ slot: Int) -> Color { MetricStyle.internet.shade(slot, of: 6) }

    /// Seconds between latency probes.
    private static let probeInterval: TimeInterval = 5

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    kpiStrip(proxy)
                    throughputSection
                    WeightedHStack(weights: [3, 2]) {
                        latencySection.id(Anchor.latency)
                        pathSection
                    }
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
        // Wi‑Fi signal and PHY are read only while this page is on screen.
        .onAppear { metrics.networkAppeared() }
        .onDisappear { metrics.networkDisappeared() }
    }

    /// What the live throughput buffers span: their capacity at the sampling interval.
    private var liveWindow: TimeInterval { Double(metrics.downHistory.capacity) * metrics.samplingInterval }

    private var internetStats: LatencyStats { LatencyStats(metrics.latencyHistory.values) }

    private var isWiFi: Bool { metrics.network?.interfaceKind == NetworkCollector.wifiKind }

    // MARK: KPI strip

    private func kpiStrip(_ proxy: ScrollViewProxy) -> some View {
        let stats = internetStats
        let moved = metrics.transferredLast5Minutes
        let total = Format.bytesFigure(Int64(moved.down + moved.up))
        return WeightedHStack(weights: [1.6, 1, 1, 1]) {
            connectionTile
            KPITile(title: "Latency to internet", style: .internet,
                    health: stats.current.map { metrics.latencyThreshold.health(for: $0) },
                    value: stats.current.map { "\(Int($0.rounded()))" } ?? (stats.probes > 0 ? "Timeout" : nil),
                    unit: stats.current == nil ? nil : "ms",
                    caption: joined([stats.p95.map { "p95 \(Format.ms($0))" },
                                     stats.jitter.map { "jitter \(Format.ms($0))" }])) {
                withAnimation { proxy.scrollTo(Anchor.latency, anchor: .top) }
            }
            KPITile(title: "Packet loss · 5 m", style: .internet,
                    value: stats.lossPercent.map { "\(Int($0.rounded()))" }, unit: "%",
                    caption: stats.probes > 0
                        ? "\(stats.timeouts) timeout\(stats.timeouts == 1 ? "" : "s") of \(stats.probes) probes" : nil)
            KPITile(title: "Transferred · 5 m", style: .network,
                    value: metrics.network == nil ? nil : total.number, unit: total.unit,
                    caption: metrics.network == nil ? nil
                        : "↓ \(Format.bytesShort(Int64(moved.down))) · ↑ \(Format.bytesShort(Int64(moved.up)))")
        }
    }

    private var connectionTile: some View {
        let health = metrics.networkHealth
        let offline = health?.connectivity == .offline || (metrics.network != nil && metrics.network?.interface == nil)
        let symbol = offline ? (isWiFi ? "wifi.slash" : "network.slash")
            : isWiFi ? "wifi" : metrics.network?.interfaceKind == "Ethernet" ? "cable.connector" : "network"
        let title = offline ? "Offline"
            : health.map { "Connected · \(Format.health($0.health))" } ?? (metrics.network?.interface == nil ? "Checking…" : "Connected")
        let n = metrics.network
        let subtitle = joined([n?.interfaceKind, isWiFi ? metrics.wifi?.phy : nil, n?.localIPv4,
                               isWiFi ? metrics.wifi?.rssiDBm.map(Format.dBm) : nil])
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(MetricStyle.network.tint)
                .frame(width: 40, height: 40)
                .background(MetricStyle.network.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.headline).lineLimit(1)
                    if offline {
                        SeverityMark(level: .critical, font: .caption)
                    } else if let level = health?.health {
                        SeverityMark(level: level, font: .caption)
                    }
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardBackground(padding: 0)
        .accessibilityElement(children: .combine)
    }

    // MARK: Throughput

    private var throughputSection: some View {
        let n = metrics.network
        let subtitle = n?.interface.map { name in joined([n?.interfaceKind, name]) ?? name } ?? "No connection"
        return Section2(title: "Throughput", subtitle: subtitle) {
            HStack(spacing: 14) {
                if let n {
                    legend("Download", Format.rate(n.downBytesPerSec), tint: MetricStyle.network.tint)
                    legend("Upload", Format.rate(n.upBytesPerSec), tint: MetricStyle.upload.tint)
                }
                Picker("Scale", selection: $scale) {
                    Text("Log").tag(ChartScale.signedLog)
                    Text("Linear").tag(ChartScale.linear)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Log scale keeps a quiet link readable next to a burst")
            }
        } content: {
            Group {
                if range == .live {
                    TimeSeriesChart(series: [.init(name: "Download", values: metrics.downHistory.values, tint: MetricStyle.network.tint),
                                             .init(name: "Upload", values: metrics.upHistory.values, tint: MetricStyle.upload.tint)],
                                    interval: metrics.samplingInterval, window: liveWindow,
                                    format: { $0 < 1 ? "0" : Format.rate($0) }, showsLegend: false,
                                    accessibilityTitle: "Network throughput", mirrored: true, scale: scale)
                } else {
                    HistoryChart(history: metrics.history,
                                 lines: [.init(kind: .networkDownBytesPerSec, name: "Download", tint: MetricStyle.network.tint),
                                         .init(kind: .networkUpBytesPerSec, name: "Upload", tint: MetricStyle.upload.tint)],
                                 range: range, format: { $0 < 1 ? "0" : Format.rate($0) },
                                 accessibilityTitle: "Network throughput", mirrored: true, scale: scale)
                }
            }
            .frame(height: 180)
            // Live only: stored ranges keep min/max inside the chart, and a peak read from them
            // would need its own query.
            if range == .live, let line = peakLine {
                InsetNote {
                    Circle().fill(MetricStyle.network.tint).frame(width: 7, height: 7)
                    line
                }
            }
        }
    }

    private func legend(_ name: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(tint).frame(width: 12, height: 3)
            Text(name).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.caption)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// "Peak download 5.4 MB/s at 14:33 · upload 1.1 MB/s at 14:35" over the live window.
    private var peakLine: Text? {
        func part(_ label: String, _ peak: (bytesPerSec: Double, time: Date)?) -> Text? {
            guard let peak, peak.bytesPerSec > 0 else { return nil }
            return Text("\(label) ").foregroundStyle(.secondary)
                + Text(Format.rate(peak.bytesPerSec)).fontWeight(.semibold)
                + Text(" at \(peak.time.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
        }
        let parts = [part("Peak download", metrics.peakDown), part("upload", metrics.peakUp)].compactMap { $0 }
        guard var line = parts.first else { return nil }
        for next in parts.dropFirst() { line = line + Text(" · ").foregroundStyle(.secondary) + next }
        return line
    }

    // MARK: Latency

    private var latencySection: some View {
        let threshold = metrics.latencyThreshold
        let target = metrics.networkHealth?.internet.map { $0.host ?? $0.address }
        let subtitle = range == .live
            ? joined([target.map { "to \($0)" }, "probe every \(Int(Self.probeInterval)) s"])
            : "Internet, second target, gateway and DNS"
        return Section2(title: "Latency", subtitle: subtitle) {
            if range == .live { bandLegend(threshold) }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if range == .live {
                        TimeSeriesChart(series: [.init(name: "Latency", values: metrics.latencyHistory.values,
                                                       tint: MetricStyle.internet.tint)],
                                        interval: Self.probeInterval,
                                        window: Double(metrics.latencyHistory.capacity) * Self.probeInterval,
                                        format: { "\(Int($0)) ms" }, showsLegend: false,
                                        accessibilityTitle: "Latency to internet",
                                        bands: [.init(range: 0...threshold.warning, tint: HealthLevel.healthy.tint),
                                                .init(range: threshold.warning...threshold.critical, tint: HealthLevel.warning.tint),
                                                .init(range: threshold.critical...Double.infinity, tint: HealthLevel.critical.tint)],
                                        markers: true, markerThreshold: threshold.warning,
                                        gapBars: HealthLevel.critical.tint)
                    } else {
                        HistoryChart(history: metrics.history, lines: Self.latencyLines(targets: metrics.probeTargets),
                                     range: range, format: { "\(Int($0)) ms" }, accessibilityTitle: "Latency")
                    }
                }
                .frame(height: 180)
                if range == .live { latencyFooter(threshold) }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// "Healthy < 100 · Warning < 300 · Critical", each level in its own readable tint.
    private func bandLegend(_ threshold: Threshold) -> some View {
        func name(_ level: HealthLevel) -> Text {
            Text(Format.health(level)).foregroundStyle(level.tint.readableInk(on: .card, minimum: 4.5))
        }
        let rest = Text(" < \(Int(threshold.warning)) · ").foregroundStyle(.secondary)
        let rest2 = Text(" < \(Int(threshold.critical)) · ").foregroundStyle(.secondary)
        return (name(.healthy) + rest + name(.warning) + rest2 + name(.critical))
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private func latencyFooter(_ threshold: Threshold) -> some View {
        let stats = internetStats
        return HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(HealthLevel.warning.markTint).frame(width: 7, height: 7)
                Text("Spike ≥ \(Format.ms(threshold.warning))")
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1).fill(HealthLevel.critical.markTint).frame(width: 4, height: 10)
                Text("Timeout (\(stats.timeouts))")
            }
            Spacer(minLength: 12)
            if let summary = joined([stats.median.map { "Median \(Format.ms($0))" },
                                     stats.p95.map { "p95 \(Format.ms($0))" },
                                     stats.max.map { "max \(Format.ms($0))" }]) {
                Text(summary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    // MARK: Path

    private var pathSection: some View {
        let h = metrics.networkHealth
        return Section2(title: "Path", subtitle: "where latency comes from") {
            // `SettingsLink` takes the click before any gesture beside it, so it cannot choose the tab.
            Button("Edit targets") {
                settingsTab = SettingsView.Tab.network.rawValue
                openSettings()
            }
            .buttonStyle(.link)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if let h {
                    let rows = pathRows(h)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider() }
                        PathRow(row: row)
                    }
                } else {
                    InlineEmpty("Probes report within \(Int(Self.probeInterval)) s.")
                }
                Spacer(minLength: 12)
                if let insight = metrics.pathInsight {
                    InsetNote {
                        SeverityMark(level: insight.level, font: .caption)
                        Text(insight.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func pathRows(_ h: NetworkHealthReading) -> [PathRow.Model] {
        var rows: [PathRow.Model] = []
        if let g = h.gateway {
            rows.append(.init(symbol: "wifi.router", name: "Gateway", address: g.address,
                              series: metrics.gatewayLatencyHistory.values, showsLoss: true, tint: Self.pathTint(2)))
        }
        if let d = h.dns {
            rows.append(.init(symbol: "text.magnifyingglass", name: "DNS resolver", address: "\(d.server) · lookup",
                              series: metrics.dnsLatencyHistory.values, showsLoss: false, tint: Self.pathTint(3)))
        }
        if let primary = h.internet {
            rows.append(targetRow(primary, series: metrics.latencyHistory.values, slot: 0))
        }
        // Comparison slots: the first shares history slot 2's shade; the rest take 4 and 5.
        for (index, probe) in h.comparisons.enumerated() {
            let series = metrics.comparisonLatencyHistories[probe.host ?? probe.address]?.values ?? []
            rows.append(targetRow(probe, series: series, slot: index == 0 ? 1 : 3 + index))
        }
        return rows
    }

    private func targetRow(_ probe: ProbeReading, series: [Double], slot: Int) -> PathRow.Model {
        let name = Format.targetName(label: probe.label, address: probe.address, host: probe.host)
        // A host name shows what it resolved to; an address is its own subtitle.
        let subtitle = probe.host.flatMap { host in
            host == probe.address || probe.unresolved ? nil : "\(host) · \(probe.address)"
        } ?? probe.host ?? probe.address
        return .init(symbol: "globe", name: "Internet · \(name)", address: subtitle, series: series,
                     showsLoss: true, tint: Self.pathTint(slot), unresolved: probe.unresolved)
    }

    /// Non-nil parts joined with " · "; nil when none are.
    private func joined(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }
}

/// One probe on the way out: where it goes, its latest round trip, 5 min loss and a sparkline.
private struct PathRow: View {
    struct Model {
        let symbol: String
        let name: String
        let address: String
        let series: [Double]
        /// DNS lookups are not pings; their failures are not packet loss.
        let showsLoss: Bool
        let tint: Color
        /// A host name that did not resolve: nothing was probed, so no figure and no line.
        var unresolved = false
    }

    let row: Model

    var body: some View {
        let stats = LatencyStats(row.series)
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.caption)
                .foregroundStyle(row.tint)
                .frame(width: 26, height: 26)
                .background(row.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(row.address).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Group {
                if row.unresolved {
                    Text("can't resolve").foregroundStyle(HealthLevel.warning.tint.readableInk(on: .card, minimum: 4.5))
                } else if let current = stats.current {
                    Text(Format.ms(current)).fontWeight(.semibold)
                } else if stats.probes > 0 {
                    Text("timeout").foregroundStyle(HealthLevel.critical.tint.readableInk(on: .card, minimum: 4.5))
                }
            }
            .font(.callout)
            .monospacedDigit()
            .frame(minWidth: 56, alignment: .trailing)
            status(row.unresolved ? LatencyStats([]) : stats)
                .font(.caption)
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
            Group {
                if row.unresolved {
                    Color.clear
                } else {
                    Sparkline(values: row.series, tint: row.tint, points: 60, height: 22, lineWidth: 1.2)
                }
            }
            .frame(width: 72, height: 22)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    /// Loss draws attention only when there is some; a clean path stays quiet (PRD §15).
    @ViewBuilder
    private func status(_ stats: LatencyStats) -> some View {
        if row.showsLoss, let loss = stats.lossPercent {
            Text("\(Format.percent(loss)) loss")
                .foregroundStyle(loss > 0 ? AnyShapeStyle(HealthLevel.warning.tint.readableInk(on: .card, minimum: 4.5))
                                          : AnyShapeStyle(.secondary))
        } else if !row.showsLoss, stats.current != nil {
            Text("ok").foregroundStyle(.secondary)
        }
    }
}

/// A quiet line inside a card: the throughput peak, the path insight.
private struct InsetNote<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) { content }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
    }
}
