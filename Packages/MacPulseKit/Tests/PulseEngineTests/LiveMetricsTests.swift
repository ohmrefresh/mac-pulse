import Foundation
import Testing
import PulseCore
import PulseCollectors
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

    @Test func alertsFireIntoTimelineAndCallback() {
        let m = LiveMetrics()
        var rule = AlertRule.templates.first { $0.name == "High CPU" }!
        rule.isEnabled = true
        rule.duration = 0
        m.setAlertRules([rule])
        var delivered: [AlertEvent] = []
        m.onAlert = { delivered.append($0) }

        var s = Snapshot()
        s.cpu = CPUReading(totalPercent: 95, perCorePercent: [95])
        m.apply(s)
        #expect(m.firingAlertIDs == [rule.id])
        #expect(delivered.map(\.kind) == [.fired])
        #expect(m.recentEvents.last?.title == "High CPU")
        #expect(m.recentEvents.last?.detail == "CPU 95% · rule > 90%")
        #expect(m.recentEvents.last?.severity == .warning)

        s.cpu = CPUReading(totalPercent: 10, perCorePercent: [10])
        m.apply(s)
        #expect(m.firingAlertIDs.isEmpty)
        #expect(m.recentEvents.last?.title == "High CPU resolved")
    }

    @Test func latencyTimeoutFeedsAlertAsInfinite() {
        let m = LiveMetrics()
        var rule = AlertRule.templates.first { $0.metric == .latencyMs }!
        rule.isEnabled = true
        rule.duration = 0
        m.setAlertRules([rule])
        m.apply(.make(connectivity: .online, gateway: nil,
                      internet: ProbeReading(address: "1.1.1.1", latencyMs: nil, lossPercent: 100),
                      thresholds: NetworkThresholds()))
        #expect(m.recentEvents.last?.detail == "Internet latency timeout · rule > 300 ms")
    }
}
