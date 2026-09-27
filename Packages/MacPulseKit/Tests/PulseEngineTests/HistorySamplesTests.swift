import Foundation
import Testing
import PulseCore
import PulseCollectors
@testable import PulseEngine

@Suite struct HistorySamplesTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mapsOnlyPresentReadings() {
        var s = Snapshot()
        s.cpu = CPUReading(totalPercent: 21, perCorePercent: [21])
        s.thermal = .serious
        let rows = HistorySamples.from(s, at: t)
        #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.kind, $0.value) }) == [.cpuPercent: 21, .thermalState: 2])
    }

    @Test func temperaturesIncludeSSDBatteryAndHottest() {
        var s = Snapshot()
        s.sensors = SensorsReading(cpuCelsius: 38, ssdCelsius: 34, batteryCelsius: 31,
                                   sensors: [TemperatureSensor(name: "PMU tcal", celsius: 52), TemperatureSensor(name: "PMU tdie1", celsius: 38)],
                                   fans: [])
        let values = Dictionary(uniqueKeysWithValues: HistorySamples.from(s, at: t).map { ($0.kind, $0.value) })
        #expect(values[.cpuTemperatureC] == 38 && values[.ssdTemperatureC] == 34)
        #expect(values[.batteryTemperatureC] == 31 && values[.hottestTemperatureC] == 52)
    }

    @Test func probeReadingsSkipOfflineAndTimeouts() {
        let th = NetworkThresholds()
        let online = NetworkHealthReading.make(connectivity: .online,
                                               gateway: ProbeReading(address: "10.0.0.1", latencyMs: nil, lossPercent: 50),
                                               internet: ProbeReading(address: "1.1.1.1", latencyMs: 18, lossPercent: 0),
                                               secondary: ProbeReading(address: "8.8.8.8", latencyMs: 20, lossPercent: 0),
                                               dns: DNSReading(server: "10.0.0.1", latencyMs: 420),
                                               thresholds: th)
        let values = Dictionary(uniqueKeysWithValues: HistorySamples.from(online, at: t).map { ($0.kind, $0.value) })
        #expect(values == [.latencyMs: 18, .packetLossPercent: 0, .secondaryLatencyMs: 20, .dnsLatencyMs: 420])
        let offline = NetworkHealthReading.make(connectivity: .offline, gateway: nil, internet: nil, thresholds: th)
        #expect(HistorySamples.from(offline, at: t).isEmpty)
    }

    @Test func topProcessesUnionOfCPUAndMemoryWithoutDuplicates() {
        let rows = (1...30).map { i in
            ProcessRow(pid: Int32(i), name: "p\(i)", cpuPercent: Double(i), memoryBytes: UInt64(31 - i), isPrivileged: false)
        }
        let top = HistorySamples.topProcesses(rows, at: t, limit: 3)
        // CPU top: 30, 29, 28. Memory top: 1, 2, 3.
        #expect(top.map(\.pid) == [30, 29, 28, 1, 2, 3])
        let both = HistorySamples.topProcesses([rows[0]], at: t, limit: 3)
        #expect(both.count == 1)
    }
}

@Suite struct ProberTargetTests {
    @Test func secondaryTargetDiffersFromPrimary() {
        #expect(Prober.secondaryTarget(for: "1.1.1.1") == "8.8.8.8")
        #expect(Prober.secondaryTarget(for: "8.8.8.8") == "1.1.1.1")
        #expect(Prober.secondaryTarget(for: "9.9.9.9") == "8.8.8.8")
    }
}
