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

    private func probe(_ ms: Double?) -> ProbeReading { ProbeReading(address: "x", latencyMs: ms, lossPercent: 0) }

    /// Path series use NaN for a timed-out probe, but record nothing for a probe that does not exist
    /// (no IPv4 router behind a VPN): a missing gateway must not read as 100 % loss.
    @Test func pathSeriesRecordTimeoutsButNotAbsentProbes() {
        let m = LiveMetrics()
        m.apply(NetworkHealthReading(connectivity: .online, gateway: probe(3), internet: probe(20),
                                     comparisons: [ProbeReading(address: "8.8.8.8", latencyMs: nil, lossPercent: 0, host: "8.8.8.8")],
                                     dns: DNSReading(server: "1.1.1.1", latencyMs: 15), health: .healthy))
        m.apply(NetworkHealthReading(connectivity: .online, gateway: nil, internet: probe(21),
                                     dns: nil, health: .healthy))
        #expect(m.gatewayLatencyHistory.values == [3])
        let comparison = try! #require(m.comparisonLatencyHistories["8.8.8.8"])
        #expect(comparison.values.count == 1 && comparison.values[0].isNaN)
        #expect(m.dnsLatencyHistory.values == [15])
        #expect(m.latencyHistory.values == [20, 21])
    }

    @Test func pathSeriesSkipOfflineReadings() {
        let m = LiveMetrics()
        m.apply(NetworkHealthReading(connectivity: .offline, gateway: probe(nil), internet: nil, health: .critical))
        #expect(m.gatewayLatencyHistory.count == 0)
    }

    @Test func pathInsightUsesTheLiveSeries() {
        let m = LiveMetrics()
        #expect(m.pathInsight == nil)
        for ms in [3.0, 4, 5] {
            m.apply(NetworkHealthReading(connectivity: .online, gateway: probe(3), internet: probe(ms == 4 ? 400 : 20), health: .healthy))
        }
        #expect(m.pathInsight?.text.hasPrefix("Spikes appear only past the gateway") == true)
    }

    /// Wi‑Fi details are only meaningful while the Network page is up: reference-counted, cleared on the last close.
    @Test func networkGateIsReferenceCountedAndClearsWiFi() {
        let m = LiveMetrics()
        var s = Snapshot()
        s.wifi = WiFiReading(rssiDBm: -54, phy: "Wi‑Fi 6")
        m.networkAppeared()
        m.networkAppeared()
        m.apply(s)
        #expect(m.wifi?.rssiDBm == -54)
        m.networkDisappeared()
        #expect(m.wifi != nil)            // still one viewer
        m.networkDisappeared()
        #expect(m.wifi == nil)
        m.networkDisappeared()            // unbalanced call must not underflow
        m.networkAppeared()
        m.apply(s)
        #expect(m.wifi != nil)
    }

    @Test func wifiClearsWhenThePrimaryIsNotWiFi() {
        let m = LiveMetrics()
        m.networkAppeared()
        var s = Snapshot()
        s.wifi = WiFiReading(rssiDBm: -54, phy: nil)
        m.apply(s)
        var e = Snapshot()
        e.network = NetworkReading(interface: "en5", interfaceKind: "Ethernet", downBytesPerSec: 0, upBytesPerSec: 0)
        m.apply(e)
        #expect(m.wifi == nil)
    }

    @Test func transferredAndPeakFollowTheThroughputSeries() {
        let m = LiveMetrics(baseInterval: 1)
        for (down, up) in [(100.0, 10.0), (300, 5), (200, 20)] {
            var s = Snapshot()
            s.cpu = CPUReading(totalPercent: 0, perCorePercent: [])
            s.network = NetworkReading(interface: "en0", downBytesPerSec: down, upBytesPerSec: up)
            m.apply(s)
        }
        #expect(m.transferredLast5Minutes.down == 600)
        #expect(m.transferredLast5Minutes.up == 35)
        let last = try! #require(m.lastSampleAt)
        #expect(m.peakDown?.bytesPerSec == 300)
        #expect(m.peakDown?.time == last.addingTimeInterval(-1))
        #expect(m.peakUp?.bytesPerSec == 20)
        #expect(m.peakUp?.time == last)
    }

    @Test func latencyThresholdFollowsConfigureNetwork() {
        let m = LiveMetrics()
        #expect(m.latencyThreshold == NetworkThresholds().latencyMs)
        m.configureNetwork(targets: ProbeTargets.defaults,
                           thresholds: NetworkThresholds(latencyMs: Threshold(warning: 50, critical: 150)))
        #expect(m.latencyThreshold == Threshold(warning: 50, critical: 150))
    }

    private func comparison(_ host: String, _ ms: Double?, unresolved: Bool = false) -> ProbeReading {
        ProbeReading(address: host, latencyMs: ms, lossPercent: nil, host: host, unresolved: unresolved)
    }

    /// Can't-resolve is not a timeout: it appends nothing, so it never reads as loss.
    @Test func unresolvedTargetsAppendNothing() {
        let m = LiveMetrics()
        m.apply(NetworkHealthReading(connectivity: .online, gateway: nil,
                                     internet: comparison("x.invalid", nil, unresolved: true),
                                     comparisons: [comparison("y.invalid", nil, unresolved: true)], health: .warning))
        #expect(m.latencyHistory.count == 0)
        #expect(m.comparisonLatencyHistories["y.invalid"] == nil)
    }

    @Test func configureNetworkPrunesRemovedComparisonSeriesAndSanitizes() {
        let m = LiveMetrics()
        m.configureNetwork(targets: [ProbeTarget("1.1.1.1"), ProbeTarget("8.8.8.8"), ProbeTarget("9.9.9.9")], thresholds: NetworkThresholds())
        m.apply(NetworkHealthReading(connectivity: .online, gateway: nil, internet: probe(20),
                                     comparisons: [comparison("8.8.8.8", 20), comparison("9.9.9.9", 30)], health: .healthy))
        #expect(Set(m.comparisonLatencyHistories.keys) == ["8.8.8.8", "9.9.9.9"])
        m.configureNetwork(targets: [ProbeTarget("1.1.1.1"), ProbeTarget("9.9.9.9"), ProbeTarget("bad target")], thresholds: NetworkThresholds())
        #expect(Set(m.comparisonLatencyHistories.keys) == ["9.9.9.9"])
        #expect(m.probeTargets.map(\.address) == ["1.1.1.1", "9.9.9.9"])
    }

    @Test func targetListEditsPostATimelineEventButTheFirstConfigureDoesNot() {
        let m = LiveMetrics()
        m.configureNetwork(targets: ProbeTargets.defaults, thresholds: NetworkThresholds())
        m.configureNetwork(targets: ProbeTargets.defaults, thresholds: NetworkThresholds())
        #expect(!m.recentEvents.contains { $0.title == "Internet targets changed" })
        m.configureNetwork(targets: [ProbeTarget("9.9.9.9")], thresholds: NetworkThresholds())
        #expect(m.recentEvents.last?.title == "Internet targets changed")
        #expect(m.recentEvents.last?.detail == "9.9.9.9")
    }

    @Test func pathInsightNamesTheOneSlowComparison() {
        let m = LiveMetrics()
        m.configureNetwork(targets: [ProbeTarget("1.1.1.1"), ProbeTarget("github.com", label: "GitHub")], thresholds: NetworkThresholds())
        var gh = comparison("140.82.112.4", 400)
        gh.host = "github.com"; gh.label = "GitHub"
        m.apply(NetworkHealthReading(connectivity: .online, gateway: probe(3), internet: probe(20), comparisons: [gh], health: .healthy))
        #expect(m.pathInsight?.text == "Only GitHub is slow — possibly that server or its network.")
    }

    /// A latency alert must not fire because a name stopped resolving: there is no latency to compare.
    @Test func unresolvedPrimaryDoesNotFireALatencyAlert() {
        let m = LiveMetrics()
        m.setAlertRules([AlertRule(name: "Slow", metric: .latencyMs, comparator: .above, threshold: 100,
                                   duration: 0, severity: .warning, isEnabled: true)])
        m.apply(NetworkHealthReading(connectivity: .online, gateway: nil,
                                     internet: comparison("x.invalid", nil, unresolved: true), health: .warning))
        #expect(m.firingAlertIDs.isEmpty)
    }
}
