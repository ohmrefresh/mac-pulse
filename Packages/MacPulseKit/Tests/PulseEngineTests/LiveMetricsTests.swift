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

    @Test func batteryAndTemperatureHistoriesAndCPUHealth() {
        let m = LiveMetrics()
        var s = Snapshot()
        s.battery = BatteryReading(percent: 80, isCharging: false, onACPower: false, minutesRemaining: nil,
                                   cycleCount: nil, maximumCapacityPercent: nil)
        s.sensors = SensorsReading(cpuCelsius: 52, ssdCelsius: nil, batteryCelsius: nil, sensors: [], fans: [])
        s.cpu = CPUReading(totalPercent: 20, perCorePercent: [20])
        m.apply(s)
        #expect(m.batteryHistory.values == [80])
        #expect(m.temperatureHistory.values == [52])
        #expect(m.cpuHealth == .healthy)
        #expect(m.cpuFiveMinutePeak == 20)
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

    @Test func temperatureAndGPUFeedAlerts() {
        let m = LiveMetrics()
        var rule = AlertRule.templates.first { $0.name == "Hot CPU" }!
        rule.isEnabled = true
        rule.duration = 0
        m.setAlertRules([rule])
        var s = Snapshot()
        s.sensors = SensorsReading(cpuCelsius: 98, ssdCelsius: nil, batteryCelsius: nil, sensors: [], fans: [])
        m.apply(s)
        #expect(m.recentEvents.last?.detail == "CPU temperature 98°C · rule > 95°C")
        #expect(m.menuBarInputs.cpuCelsius == 98)
    }

    @Test func splitTunnelVPNReachesTimeline() {
        let m = LiveMetrics()
        m.apply(DeveloperSnapshot(networkConfig: NetworkConfigReading(primaryInterface: "en0", vpnInterfaces: [], proxies: [])))
        m.apply(DeveloperSnapshot(networkConfig: NetworkConfigReading(primaryInterface: "en0", vpnInterfaces: ["utun6"], proxies: [])))
        #expect(m.recentEvents.last?.title == "VPN connected")
    }
}
