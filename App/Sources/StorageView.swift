import SwiftUI
import PulseCore
import PulseCollectors
import PulseEngine
import PulseStore

/// Storage page (after `docs/prd/mock_v2.html`): the startup disk's free space with its 30-day
/// trend, then every mounted Volume. Only capacity is measured — no category split, no
/// reclaimable estimate, no drive health — so none is shown. Disk has no Health Level.
struct StorageView: View {
    let metrics: LiveMetrics
    @State private var trend: HistorySeries?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let d = metrics.disk {
                    hero(d)
                    // The startup disk alone would repeat the card above.
                    if metrics.volumes.count > 1 { volumes }
                } else {
                    ContentUnavailableView("No disk data yet", systemImage: MetricStyle.disk.symbol)
                }
            }
            .padding(24)
        }
        .task {
            // Free space is stored at the disk job's 60 s cadence; reloading every few minutes is plenty.
            while !Task.isCancelled {
                await loadTrend()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    // MARK: Hero

    private func hero(_ d: DiskReading) -> some View {
        let figure = Format.bytesFigure(d.availableBytes)
        let used = Double(d.usedBytes) / Double(max(d.totalBytes, 1))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(d.volumeName ?? "Startup disk").font(.title3.weight(.semibold))
                        Text(StorageText.descriptor(d)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        FigureText(number: figure.number, unit: figure.unit.map { "\($0) free" },
                                   size: .system(size: 36), unitSize: .title3)
                        Text("· \(Format.bytesShort(d.usedBytes)) used · \(Format.percent(used * 100))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer(minLength: 16)
                if let trend, let delta = StorageText.trendDelta(trend.points.map(\.avg)) {
                    trendView(trend, delta: delta)
                }
            }
            UsageBar(fraction: used, tint: MetricStyle.disk.tint)
            Text("Free includes purgeable space, matching Finder. Refreshed every 60 s.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// "30-day trend", its sparkline, and how much free space changed. Disk has no Health Level, so
    /// the figure stays neutral and its sign alone says which way it went.
    private func trendView(_ series: HistorySeries, delta: Int64) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(StorageText.trendTitle(since: series.points.first?.time)).font(.caption).foregroundStyle(.secondary)
            Sparkline(values: series.points.map(\.avg), tint: MetricStyle.disk.tint,
                      points: series.points.count, height: 28)
                .frame(width: 140)
            Text(StorageText.signedBytes(delta))
                .font(.callout.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(StorageText.trendTitle(since: series.points.first?.time)) of free space: \(delta < 0 ? "down" : "up") \(Format.bytesShort(abs(delta)))")
    }

    // MARK: Volumes

    private var volumes: some View {
        let list = metrics.volumes
        return Section2(title: "Volumes", subtitle: "\(list.count) mounted") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, volume in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(volume.volumeName ?? volume.mountPath ?? "Volume").fontWeight(.medium).lineLimit(1)
                            if StorageText.isExternal(volume) == true {
                                Text("· external").foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text("\(Format.bytesShort(volume.usedBytes)) / \(Format.bytesShort(volume.totalBytes))")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        MeterBar(fraction: Double(volume.usedBytes) / Double(max(volume.totalBytes, 1)),
                                 tint: MetricStyle.disk.tint)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func loadTrend() async {
        guard let history = metrics.history else { return }
        let to = Date(), from = to.addingTimeInterval(-ChartRange.month.rawValue)
        trend = try? await Task.detached {
            try history.chartSeries(.diskFreeBytes, from: from, to: to, maxPoints: 60)
        }.value
    }
}

/// The Storage page's wording, kept out of the view so it can be tested.
enum StorageText {
    /// Fewer stored points than this is too little to call a trend.
    static let minimumTrendPoints = 4

    /// External when the volume says it is removable or not internal; nil when it says neither.
    static func isExternal(_ d: DiskReading) -> Bool? {
        if d.isRemovable == true || d.isInternal == false { return true }
        if d.isInternal == true { return false }
        return nil
    }

    /// "995 GB · internal", or the size alone when the volume doesn't say where it is.
    static func descriptor(_ d: DiskReading) -> String {
        let location = isExternal(d).map { $0 ? "external" : "internal" }
        return [Format.bytesShort(d.totalBytes), location].compactMap { $0 }.joined(separator: " · ")
    }

    /// Free bytes at the newest stored point minus the oldest; nil with too little history.
    static func trendDelta(_ freeBytes: [Double]) -> Int64? {
        guard freeBytes.count >= minimumTrendPoints, let first = freeBytes.first, let last = freeBytes.last else { return nil }
        return Int64((last - first).rounded())
    }

    /// "30-day trend" only when history reaches back that far; otherwise the span it does cover
    /// ("2-day trend"), so the label never claims more than was recorded.
    static func trendTitle(since oldest: Date?, now: Date = Date()) -> String {
        guard let oldest else { return "Trend" }
        let days = min(max(Int((now.timeIntervalSince(oldest) / 86_400).rounded()), 1), 30)
        return "\(days)-day trend"
    }

    /// "−41 GB", "+3.2 GB", with a true minus sign.
    static func signedBytes(_ delta: Int64) -> String {
        (delta < 0 ? "\u{2212}" : "+") + Format.bytesShort(abs(delta))
    }
}
