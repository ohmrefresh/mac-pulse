import Foundation
import Testing
import PulseCore
@testable import PulseStore

@Suite struct HistoryStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // multiple of 300 s: bucket-aligned

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// One CPU sample per second in [start, end) with value = seconds offset.
    private func cpu(_ range: Range<Int>) -> [MetricSample] {
        range.map { MetricSample(kind: .cpuPercent, value: Double($0), timestamp: at(Double($0))) }
    }

    @Test func rollsUpOnlyCompletedTenSecondBuckets() throws {
        let store = try HistoryStore(url: nil)
        try store.write(samples: cpu(0..<35), processes: [], now: at(35), retention: .thirtyDays)
        let points = try store.series(.cpuPercent, from: at(0), to: at(35), now: at(2 * 3600))   // force 10 s tier
        #expect(points.map(\.time) == [at(0), at(10), at(20)])
        #expect(points[0] == HistoryPoint(time: at(0), min: 0, avg: 4.5, max: 9))
        #expect(points[2].avg == 24.5)
    }

    @Test func minuteTierUsesCountWeightedAverage() throws {
        let store = try HistoryStore(url: nil)
        try store.write(samples: cpu(0..<130), processes: [], now: at(130), retention: .thirtyDays)
        let minutes = try store.series(.cpuPercent, from: at(0), to: at(130), now: at(3 * 86_400))  // force 1 min tier
        #expect(minutes.map(\.time) == [at(0), at(60)])
        #expect(minutes[0] == HistoryPoint(time: at(0), min: 0, avg: 29.5, max: 59))
        #expect(minutes[1].avg == 89.5)
    }

    @Test func incrementalWritesMatchSingleWrite() throws {
        let once = try HistoryStore(url: nil)
        try once.write(samples: cpu(0..<95), processes: [], now: at(95), retention: .thirtyDays)

        let split = try HistoryStore(url: nil)
        try split.write(samples: cpu(0..<33), processes: [], now: at(33), retention: .thirtyDays)
        try split.write(samples: cpu(33..<64), processes: [], now: at(64), retention: .thirtyDays)
        try split.write(samples: cpu(64..<95), processes: [], now: at(95), retention: .thirtyDays)

        let later = at(2 * 3600)
        #expect(try once.series(.cpuPercent, from: at(0), to: at(95), now: later)
                == split.series(.cpuPercent, from: at(0), to: at(95), now: later))
    }

    @Test func rawTierServesRecentRangesAndSkipsNonFinite() throws {
        let store = try HistoryStore(url: nil)
        var samples = cpu(0..<5)
        samples.append(MetricSample(kind: .latencyMs, value: .nan, timestamp: at(1)))
        try store.write(samples: samples, processes: [], now: at(5), retention: .thirtyDays)
        let raw = try store.series(.cpuPercent, from: at(0), to: at(5), now: at(5))
        #expect(raw.map(\.avg) == [0, 1, 2, 3, 4])
        #expect(try store.series(.latencyMs, from: at(0), to: at(5), now: at(5)).isEmpty)
    }

    @Test func prunesRawAfterAnHourAndCapsByRetention() throws {
        let store = try HistoryStore(url: nil)
        try store.write(samples: cpu(0..<20), processes: [], now: at(20), retention: .thirtyDays)
        // Two hours later: raw samples gone, 10 s aggregates kept.
        try store.write(samples: [], processes: [], now: at(7_200), retention: .thirtyDays)
        #expect(try store.series(.cpuPercent, from: at(0), to: at(20), now: at(1_000)).isEmpty)   // raw tier
        #expect(try store.series(.cpuPercent, from: at(0), to: at(20), now: at(7_200)).count == 2) // 10 s tier

        // A 1 h retention preset removes the aggregates too.
        try store.write(samples: [], processes: [], now: at(7_200), retention: .oneHour)
        #expect(try store.series(.cpuPercent, from: at(0), to: at(20), now: at(7_200)).isEmpty)
    }

    @Test func tierSelectionByAge() {
        let now = at(0)
        #expect(HistoryStore.tier(covering: at(-3_600), now: now).table == "samples_1s")
        #expect(HistoryStore.tier(covering: at(-3_601), now: now).table == "agg_10s")
        #expect(HistoryStore.tier(covering: at(-2 * 86_400), now: now).table == "agg_1m")
        #expect(HistoryStore.tier(covering: at(-20 * 86_400), now: now).table == "agg_5m")
        #expect(HistoryStore.tier(covering: at(-90 * 86_400), now: now).table == "agg_5m")
    }

    @Test func processSamplesRoundTripAndClear() throws {
        let store = try HistoryStore(url: nil)
        let p = ProcessSample(time: at(3), pid: 400, name: "WindowServer", cpuPercent: 5.4, memoryBytes: 1 << 30)
        try store.write(samples: cpu(0..<5), processes: [p], now: at(5), retention: .thirtyDays)
        #expect(try store.processSamples(from: at(0), to: at(5)) == [p])
        try store.clear()
        #expect(try store.processSamples(from: at(0), to: at(5)).isEmpty)
        #expect(try store.series(.cpuPercent, from: at(0), to: at(5), now: at(5)).isEmpty)
    }

    @Test func onDiskDatabaseSurvivesReopen() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pulse-\(UUID().uuidString)/history.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try HistoryStore(url: url).write(samples: cpu(0..<3), processes: [], now: at(3), retention: .thirtyDays)
        #expect(try HistoryStore(url: url).series(.cpuPercent, from: at(0), to: at(3), now: at(3)).count == 3)
    }
}

@Suite struct HistoryRecorderTests {
    @Test func flushWritesBufferedSamples() async throws {
        let store = try HistoryStore(url: nil)
        let recorder = HistoryRecorder(store: store)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        await recorder.record([MetricSample(kind: .cpuPercent, value: 42, timestamp: t)])
        #expect(try store.series(.cpuPercent, from: t, to: t, now: t).isEmpty)   // buffered, not yet written
        await recorder.flush(now: t.addingTimeInterval(1))
        #expect(try store.series(.cpuPercent, from: t, to: t, now: t).map(\.avg) == [42])
        #expect(await recorder.lastError == nil)
    }
}
