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

    @Test func probeReadingsSkipOfflineAndTimeouts() {
        let th = NetworkThresholds()
        let online = NetworkHealthReading.make(connectivity: .online,
                                               gateway: ProbeReading(address: "10.0.0.1", latencyMs: nil, lossPercent: 50),
                                               internet: ProbeReading(address: "1.1.1.1", latencyMs: 18, lossPercent: 0),
                                               thresholds: th)
        #expect(Set(HistorySamples.from(online, at: t).map(\.kind)) == [.latencyMs, .packetLossPercent])
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
