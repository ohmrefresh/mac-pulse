import Foundation
import Testing
@testable import PulseCollectors

@Suite struct SensorsCollectorTests {
    @Test func groupDropsImplausibleAndAveragesDuplicates() {
        let grouped = SensorsCollector.group([("PMU tdie2", 40), ("PMU tdie2", 42), ("PMU tdev1", -9201.1),
                                              ("PMU tdie10", 39), ("NAND CH0 temp", 33), ("bogus", 400)])
        #expect(grouped.map(\.name) == ["NAND CH0 temp", "PMU tdie2", "PMU tdie10"])   // natural sort
        #expect(grouped.first { $0.name == "PMU tdie2" }?.celsius == 41)
    }

    /// Private APIs (ADR 0002): on this hardware they work; elsewhere the reading must simply be empty.
    @Test func liveReadingIsPlausibleOrEmpty() {
        let r = SensorsCollector().sample()
        if let cpu = r.cpuCelsius { #expect((10...110).contains(cpu)) }
        #expect(r.sensors.allSatisfy { (-20...130).contains($0.celsius) })
        #expect(r.fans.allSatisfy { $0.rpm >= 0 && $0.rpm < 20_000 })
        print("SENSORS cpu=\(r.cpuCelsius.map { String(format: "%.1f", $0) } ?? "-") ssd=\(r.ssdCelsius.map { String(format: "%.1f", $0) } ?? "-") sensors=\(r.sensors.count) fans=\(r.fans.map { Int($0.rpm) })")
    }
}
