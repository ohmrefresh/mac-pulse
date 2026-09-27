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

    /// The Performance page owns the fast GPU tick and the IOReport subscription, so the gate has
    /// to survive two views showing the page at once and release on the last one.
    @Test func performanceGateIsReferenceCounted() {
        let m = LiveMetrics(baseInterval: 1)
        #expect(m.gpuInterval == 5)
        m.performanceAppeared()
        m.performanceAppeared()
        #expect(m.gpuInterval == 1)
        m.performanceDisappeared()
        #expect(m.gpuInterval == 1)       // still one viewer
        m.performanceDisappeared()
        #expect(m.gpuInterval == 5)
        m.performanceDisappeared()        // unbalanced call must not underflow
        #expect(m.gpuInterval == 5)
    }

    @Test func perCoreAndMemorySplitHistoriesFollowTheSnapshot() {
        let m = LiveMetrics()
        var s = Snapshot()
        s.cpu = CPUReading(totalPercent: 20, perCorePercent: [10, 30])
        s.memory = MemoryReading(totalBytes: 100, appBytes: 40, wiredBytes: 10, compressedBytes: 5,
                                 cachedFilesBytes: 20, swapUsedBytes: 0, pressure: nil)
        s.loadAverage = LoadAverage(oneMinute: 1.5, fiveMinutes: 1, fifteenMinutes: 0.5)
        m.apply(s)
        #expect(m.perCoreHistory.count == 2)
        #expect(m.perCoreHistory.map(\.values) == [[10], [30]])
        #expect(m.memoryCachedHistory.values == [20])     // % of installed
        #expect(m.loadHistory.values == [1.5])

        // A different core count (a fresh reading after a core-count change) rebuilds the series.
        s.cpu = CPUReading(totalPercent: 5, perCorePercent: [5, 5, 5])
        m.apply(s)
        #expect(m.perCoreHistory.count == 3)
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
        #expect(m.hottestTemperatureHistory.values.isEmpty)   // no named sensors in this reading
        #expect(m.cpuHealth == .healthy)
        #expect(m.cpuFiveMinutePeak == 20)
    }

    @Test func sensorExtremesAndFifteenMinuteChange() {
        let m = LiveMetrics()
        let t0 = Date(timeIntervalSince1970: 1_000)
        func reading(_ die: Double, _ nand: Double) -> SensorsReading {
            SensorsReading(cpuCelsius: die, ssdCelsius: nand, batteryCelsius: nil,
                           sensors: [TemperatureSensor(name: "PMU tdie1", celsius: die), TemperatureSensor(name: "NAND CH0 temp", celsius: nand)],
                           fans: [])
        }
        m.applySensors(reading(40, 30), at: t0)
        m.applySensors(reading(55, 33), at: t0.addingTimeInterval(600))
        #expect(m.temperatureHistory.change(over: 900) == nil)           // spans only 10 min
        m.applySensors(reading(45, 31), at: t0.addingTimeInterval(960))
        #expect(m.temperatureHistory.change(over: 900) == 5)             // 45 now − 40 at t0
        #expect(m.hottestTemperatureHistory.values == [40, 55, 45])
        #expect(m.sensorExtremes["PMU tdie1"] == 40...55)
        #expect(m.sensorExtremes["NAND CH0 temp"] == 30...33)
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
