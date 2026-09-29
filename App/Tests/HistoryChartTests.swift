import Foundation
import Testing
import PulseCore
import PulseStore
@testable import MacPulse

/// The Latency chart once went blank on every stored range: its cache was keyed by `Line`,
/// whose `shade()` tint is a new, never-equal color on each render.
@MainActor
@Suite struct HistoryChartTests {
    @Test func seriesSurviveRebuiltLines() throws {
        let store = try HistoryStore(url: nil)
        let now = Date()
        let times = stride(from: 1_800.0, through: 0, by: -5).map { now.addingTimeInterval(-$0) }
        let kinds = NetworkDetailView.latencyLines.map(\.kind)
        let samples = kinds.flatMap { kind in times.map { MetricSample(kind: kind, value: 20, timestamp: $0) } }
        try store.write(samples: samples, processes: [], now: now, retention: .thirtyDays)

        let from = now.addingTimeInterval(-3_600)
        let loaded = try HistoryChart.loadSeries(history: store, lines: NetworkDetailView.latencyLines, from: from, to: now)

        // A second call builds new tints, exactly as the next render does.
        for line in NetworkDetailView.latencyLines {
            let points = loaded[line.kind]?.points ?? []
            #expect(!points.isEmpty, "\(line.name) lost its series after re-render")
        }
    }

    /// Why the cache must not key on `Line`. If this ever fails, SwiftUI made dynamic colors
    /// comparable and the constraint is gone — not a chart regression.
    @Test func shadeTintsAreNotStableKeys() {
        let first = NetworkDetailView.latencyLines[0].tint
        let second = NetworkDetailView.latencyLines[0].tint
        #expect(first != second)
    }
}
