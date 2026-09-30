import Testing
@testable import MacPulse

/// Live charts once re-fitted their axes to the data, so the whole chart jumped as it filled.
/// The y-axis top now moves in steps; these pin where the steps are.
@MainActor
@Suite struct TimeSeriesChartTests {
    @Test(arguments: [(0.0, 1.0), (0.4, 1), (1, 1), (1.2, 2), (3.3, 5), (5, 5), (7, 10),
                      (48, 50), (120, 200), (8_400_000, 10_000_000)])
    func axisTopRoundsUpToAStep(peak: Double, top: Double) {
        #expect(TimeSeriesChart.niceCeiling(peak) == top)
    }

    @Test func axisTopSurvivesBadReadings() {
        #expect(TimeSeriesChart.niceCeiling(.nan) == 1)
        #expect(TimeSeriesChart.niceCeiling(.infinity) == 1)
        #expect(TimeSeriesChart.niceCeiling(-3) == 1)
    }
}
