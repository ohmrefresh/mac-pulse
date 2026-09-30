import Foundation
import Testing
@testable import MacPulse

/// Throughput spans 1 KB/s to 1 GB/s on one axis only on a signed-log scale; these pin the
/// transform, its inverse and the steady decade ticks the Network charts label.
@Suite struct ChartScaleTests {
    @Test(arguments: [0.0, 1, 999, 12_345, 5_400_000, -1, -2_600_000])
    func signedLogRoundTrips(value: Double) {
        let scale = ChartScale.signedLog
        #expect(abs(scale.value(scale.plot(value)) - value) <= abs(value) * 1e-9 + 1e-9)
    }

    @Test func signedLogKeepsSign() {
        let scale = ChartScale.signedLog
        #expect(scale.plot(0) == 0)
        #expect(scale.plot(-1_000) == -scale.plot(1_000))
        #expect(abs(scale.plot(999) - 3) < 1e-9)
        #expect(scale.plot(-5) < 0)
    }

    @Test func linearIsIdentity() {
        #expect(ChartScale.linear.plot(-42.5) == -42.5)
        #expect(ChartScale.linear.value(42.5) == 42.5)
    }

    /// Below 10 MB/s the axis stays put: idle traffic must not shrink it.
    @Test func signedLogTicksKeepAMinimumTop() {
        let ticks = ChartScale.signedLog.ticks(maxMagnitude: 2_000, mirrored: false).map(ChartScale.signedLog.value)
        #expect(ticks.map { $0.rounded() } == [0, 1e3, 1e5, 1e7])
    }

    @Test func signedLogTicksGrowByTwoDecades() {
        let scale = ChartScale.signedLog
        #expect(scale.ticks(maxMagnitude: 5e7, mirrored: false).map { scale.value($0).rounded() } == [0, 1e3, 1e5, 1e7, 1e9])
        #expect(scale.top(maxMagnitude: 5e7) == scale.plot(1e9))
        #expect(scale.top(maxMagnitude: 1e7) == scale.plot(1e7))
    }

    @Test func mirroredTicksAreSymmetric() {
        let scale = ChartScale.signedLog
        let values = scale.ticks(maxMagnitude: 100, mirrored: true).map { scale.value($0).rounded() }
        #expect(values == [-1e7, -1e5, -1e3, 0, 1e3, 1e5, 1e7])
    }

    @Test func linearTicksSpanANiceTop() {
        #expect(ChartScale.linear.ticks(maxMagnitude: 66, mirrored: false) == [0, 50, 100])
        #expect(ChartScale.linear.ticks(maxMagnitude: 3.3, mirrored: true) == [-5, -2.5, 0, 2.5, 5])
        #expect(ChartScale.linear.top(maxMagnitude: 66) == 100)
    }

    @Test func badMagnitudesFallBackToTheMinimumAxis() {
        #expect(ChartScale.signedLog.top(maxMagnitude: .nan) == ChartScale.signedLog.plot(1e7))
        #expect(ChartScale.linear.top(maxMagnitude: .infinity) == 1)
    }
}
