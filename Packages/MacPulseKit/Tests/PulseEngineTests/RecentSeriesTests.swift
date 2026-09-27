import Foundation
import Testing
@testable import PulseEngine

@Suite struct RecentSeriesTests {
    @Test func keepsMostRecentInOrder() {
        var s = RecentSeries(capacity: 3)
        #expect(s.values.isEmpty && s.average == nil)
        for v in [1.0, 2, 3, 4, 5] { s.append(v) }
        #expect(s.values == [3, 4, 5])
        #expect(s.suffix(2) == [4, 5])
        #expect(s.average == 4)
    }

    @Test func partialFill() {
        var s = RecentSeries(capacity: 5)
        s.append(2); s.append(4)
        #expect(s.values == [2, 4])
        #expect(s.average == 3)
    }
}

@Suite struct TrendTests {
    private func series(_ values: [Double]) -> RecentSeries {
        var s = RecentSeries(capacity: 300)
        for v in values { s.append(v) }
        return s
    }

    @Test func nilUntilTheSeriesSpansTheMinimum() {
        // 100 samples at 1 s spans 100 s — short of the 150 s minimum.
        #expect(series(Array(repeating: 10, count: 100)).trend(interval: 1) == nil)
        #expect(series(Array(repeating: 10, count: 100)).trend(interval: 5) != nil)
    }

    @Test func currentMinusRecentAverage() throws {
        let values = Array(repeating: 10.0, count: 200) + [30]
        let trend = try #require(series(values).trend(interval: 1))
        let mean = values.reduce(0, +) / Double(values.count)
        #expect(abs(trend - (30 - mean)) < 0.001)
    }

    @Test func windowedAverageUsesWallTimeNotSampleCount() throws {
        // 300 s of 1 s samples (the capacity): the newest 150 s are all 50, the rest 0.
        let s = series(Array(repeating: 0.0, count: 150) + Array(repeating: 50.0, count: 150))
        #expect(try #require(s.average(lastSeconds: 150, interval: 1)) == 50)
        #expect(try #require(s.average(lastSeconds: 300, interval: 1)) == 25)
        // Same samples read as a 5 s series: 150 s of wall time covers only the newest 30.
        #expect(try #require(s.average(lastSeconds: 150, interval: 5)) == 50)
    }

    @Test func gapsAreIgnored() throws {
        let s = series([.nan, 10, .nan, 20])
        #expect(try #require(s.average(lastSeconds: 4, interval: 1)) == 15)
    }

    @Test func timedSeriesTrendNeedsSpanToo() throws {
        var t = TimedSeries(capacity: 240)
        let start = Date()
        for i in 0..<10 { t.append(20, at: start.addingTimeInterval(Double(i) * 5)) }   // 45 s span
        #expect(t.trend() == nil)
        for i in 10..<40 { t.append(20, at: start.addingTimeInterval(Double(i) * 5)) }  // 195 s span
        t.append(26, at: start.addingTimeInterval(200))
        #expect(try #require(t.trend()) > 5)
    }
}
