import Foundation
import Testing
@testable import PulseEngine

@Suite struct LatencyStatsTests {
    @Test func emptySeriesHasNoProbes() {
        let s = LatencyStats([])
        #expect(s.probes == 0)
        #expect(s.timeouts == 0)
        #expect(s.current == nil)
        #expect(s.median == nil)
        #expect(s.p95 == nil)
        #expect(s.max == nil)
        #expect(s.jitter == nil)
        #expect(s.lossPercent == nil)
    }

    @Test func currentIsTheLastValueAndNilAfterATimeout() {
        #expect(LatencyStats([10, 20]).current == 20)
        #expect(LatencyStats([10, .nan]).current == nil)
    }

    @Test func medianAveragesTheTwoMiddleValues() {
        #expect(LatencyStats([30, 10, 20]).median == 20)
        #expect(LatencyStats([40, 10, 30, 20]).median == 25)
    }

    /// Nearest rank: the value at ceil(0.95 × n) in ascending order.
    @Test func p95IsNearestRank() {
        let values = (1...100).map(Double.init)
        #expect(LatencyStats(values).p95 == 95)
        #expect(LatencyStats([5, 1, 3]).p95 == 5)
        #expect(LatencyStats([7]).p95 == 7)
    }

    @Test func maxIgnoresTimeouts() {
        #expect(LatencyStats([12, .nan, 40, 8]).max == 40)
    }

    @Test func allTimeoutsHaveNoLatencyFiguresButFullLoss() {
        let s = LatencyStats([.nan, .nan])
        #expect(s.probes == 2)
        #expect(s.timeouts == 2)
        #expect(s.median == nil)
        #expect(s.p95 == nil)
        #expect(s.max == nil)
        #expect(s.lossPercent == 100)
    }

    @Test func lossCountsTimeoutsOverProbes() {
        let s = LatencyStats([10, .nan, 12, 11])
        #expect(s.timeouts == 1)
        #expect(s.probes == 4)
        #expect(s.lossPercent == 25)
    }

    @Test func jitterIsMeanAbsoluteConsecutiveDifference() {
        #expect(LatencyStats([10, 20, 15]).jitter == 7.5)   // (10 + 5) / 2
    }

    /// A timeout between two replies breaks the pair: those replies are not consecutive probes.
    @Test func jitterSkipsPairsAcrossATimeout() {
        #expect(LatencyStats([10, .nan, 50, 60]).jitter == 10)
        #expect(LatencyStats([10, .nan, 50]).jitter == nil)
        #expect(LatencyStats([10]).jitter == nil)
    }
}

@Suite struct TransferredTests {
    @Test func sumsTheWindowTimesTheInterval() {
        // 1 s samples, 3 s window: last three rates × 1 s.
        #expect(Transferred.bytes(rates: [100, 1, 2, 3], interval: 1, window: 3) == 6)
    }

    @Test func scalesByInterval() {
        // 5 s samples over 300 s: last 60 samples, each × 5 s.
        let rates = Array(repeating: 10.0, count: 100)
        #expect(Transferred.bytes(rates: rates, interval: 5) == 3000)
    }

    @Test func skipsNaN() {
        #expect(Transferred.bytes(rates: [1, .nan, 2], interval: 2, window: 10) == 6)
    }

    @Test func zeroIntervalIsZero() {
        #expect(Transferred.bytes(rates: [1, 2], interval: 0) == 0)
    }
}

@Suite struct PeakTests {
    @Test func findsTheLargestFiniteSample() {
        let p = Peak.of([1, 9, .nan, 4, .infinity])
        #expect(p?.value == 9)
        #expect(p?.index == 1)
    }

    @Test func emptyOrAllNaNHasNoPeak() {
        #expect(Peak.of([]) == nil)
        #expect(Peak.of([.nan, .nan]) == nil)
    }

    @Test func tieKeepsTheLatest() {
        #expect(Peak.of([5, 2, 5])?.index == 2)
    }
}
