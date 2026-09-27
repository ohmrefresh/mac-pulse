import Foundation
import Testing
@testable import PulseCollectors

@Suite struct HardwareCollectorTests {
    @Test func parsesAppleSiliconGPUStatistics() {
        let stats: [String: Any] = ["Device Utilization %": 37, "Renderer Utilization %": 30, "In use system memory": 966_230_016]
        #expect(GPUCollector.parse(stats) == GPUReading(utilizationPercent: 37, rendererPercent: 30, memoryInUseBytes: 966_230_016))
        #expect(GPUCollector.parse(["GPU Activity(%)": 12])?.utilizationPercent == 12)   // older/Intel key
        #expect(GPUCollector.parse(["Unrelated": 1]) == nil)
    }

    @Test func liveGPUReadingIsAPercentage() throws {
        let r = try #require(GPUCollector.sample())
        #expect((0...100).contains(r.utilizationPercent))
    }

    @Test func peripheralBatteryParse() {
        #expect(PeripheralBatteryCollector.parse(product: "Magic Mouse", percent: 64) == PeripheralBattery(name: "Magic Mouse", percent: 64))
        #expect(PeripheralBatteryCollector.parse(product: nil, percent: 64) == nil)
        #expect(PeripheralBatteryCollector.parse(product: "Keyboard", percent: 255) == nil)
    }

    @Test func livePeripheralSampleIsWellFormed() {
        #expect(PeripheralBatteryCollector.sample().allSatisfy { (0...100).contains($0.percent) })
    }
}
