import Testing
@testable import MacPulse

/// The Performance tiles scale their CPU and GPU sparklines to the recent peak so a quiet Mac still
/// shows movement; these pin the steps, the 30% floor that keeps a 3% load from looking busy, and
/// the 100% ceiling.
@MainActor
@Suite struct SparklineScaleTests {
    @Test(arguments: [([Double], Double)]([([], 30), ([1, 2, 1, 3, 2, 5, 3, 2], 30), ([21], 30), ([35], 50), ([67], 90),
                      ([92], 100), ([100], 100), ([5, 8, 12, 35, 34, 6], 50), ([5, 10, 60, 10, 5], 80)]))
    func topIsPeakPlusHeadroomInSteps(values: [Double], top: Double) {
        #expect(Sparkline.percentTop(values) == top)
    }

    @Test func nearbyPeaksShareAStep() {
        #expect(Sparkline.percentTop([39]) == Sparkline.percentTop([40]))
    }

    @Test func badReadingsAreIgnored() {
        #expect(Sparkline.percentTop([.nan, 4]) == 30)
        #expect(Sparkline.percentTop([.infinity]) == 30)
    }
}
