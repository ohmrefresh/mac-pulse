import Foundation
import Testing
import PulseCore
@testable import PulseEngine

@MainActor
@Suite struct LiveMetricsTests {
    @Test func thermalChangesRecordOnlyTransitionsAndCap() {
        let m = LiveMetrics()
        var s = Snapshot()
        s.thermal = .nominal
        m.apply(s); m.apply(s)
        s.thermal = .serious
        m.apply(s)
        #expect(m.thermalChanges.map(\.state) == [.nominal, .serious])
        for i in 0..<60 { m.recordThermalChange(.fair, at: Date(timeIntervalSince1970: Double(i))) }
        #expect(m.thermalChanges.count == 50)
    }

    @Test func latencyHistoryMarksTimeoutsAndSkipsOffline() {
        let m = LiveMetrics()
        let t = NetworkThresholds()
        m.apply(.make(connectivity: .online, gateway: nil,
                      internet: ProbeReading(address: "1.1.1.1", latencyMs: 12, lossPercent: 0), thresholds: t))
        m.apply(.make(connectivity: .online, gateway: nil,
                      internet: ProbeReading(address: "1.1.1.1", latencyMs: nil, lossPercent: 50), thresholds: t))
        m.apply(.make(connectivity: .offline, gateway: nil, internet: nil, thresholds: t))
        let values = m.latencyHistory.values
        #expect(values.count == 2)
        #expect(values[0] == 12 && values[1].isNaN)
    }
}
