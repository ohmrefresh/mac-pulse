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
