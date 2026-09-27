import Testing
import PulseCore
import PulseCollectors
@testable import PulseEngine

@Suite struct MenuBarFormatterTests {
    @Test func formatsReadings() {
        let cpu = CPUReading(totalPercent: 21.4, perCorePercent: [21.4])
        let mem = MemoryReading(totalBytes: 100, appBytes: 50, wiredBytes: 10, compressedBytes: 2,
                                swapUsedBytes: 0, pressure: .normal)
        let net = NetworkReading(interface: "en0", downBytesPerSec: 8_400_000, upBytesPerSec: 1_200_000)
        let health = NetworkHealthReading.make(
            connectivity: .online, gateway: nil,
            internet: ProbeReading(address: "1.1.1.1", latencyMs: 17.6, lossPercent: 0),
            thresholds: NetworkThresholds())
        let inputs = MenuBarInputs(cpu: cpu, memory: mem, network: net, networkHealth: health, thermal: .serious)
        #expect(MenuBarFormatter.text(MenuBarItem.defaults, inputs) == "CPU 21% | MEM 62% | ↓8.4M ↑1.2M | 18ms")
        #expect(MenuBarFormatter.text([.thermal, .cpu], inputs) == "Serious | CPU 21%")
    }

    @Test func missingReadingsShowPlaceholder() {
        #expect(MenuBarFormatter.text(MenuBarItem.defaults, MenuBarInputs()) == "CPU -- | MEM -- | ↓-- ↑-- | --")
    }

    @Test func batteryOmittedWithoutBattery() {
        #expect(MenuBarFormatter.text([.cpu, .battery], MenuBarInputs()) == "CPU --")
    }

    @Test func widestCoversEveryRenderedSegment() {
        let widest = MenuBarFormatter.widestText(MenuBarItem.allCases)
        #expect(widest == "CPU 100% | MEM 100% | ↓999M ↑999M | 9999ms | BAT 100% | Critical")
        #expect("Offline".count <= "9999ms".count + 1)
    }

    @Test func rateFormatting() {
        #expect(MenuBarFormatter.rate(0) == "0K")
        #expect(MenuBarFormatter.rate(999) == "0K")
        #expect(MenuBarFormatter.rate(320_000) == "320K")
        #expect(MenuBarFormatter.rate(8_449_999) == "8.4M")
        #expect(MenuBarFormatter.rate(12_600_000) == "13M")
        #expect(MenuBarFormatter.rate(1_200_000_000) == "1.2G")
    }
}

@Suite struct NetworkHealthTests {
    private func internet(_ ms: Double?, loss: Double?) -> ProbeReading {
        ProbeReading(address: "1.1.1.1", latencyMs: ms, lossPercent: loss)
    }

    @Test func healthFollowsInternetProbe() {
        let t = NetworkThresholds()
        #expect(NetworkHealthReading.make(connectivity: .online, gateway: nil, internet: internet(18, loss: 0), thresholds: t).health == .healthy)
        #expect(NetworkHealthReading.make(connectivity: .online, gateway: nil, internet: internet(240, loss: 0), thresholds: t).health == .warning)
        #expect(NetworkHealthReading.make(connectivity: .online, gateway: nil, internet: internet(18, loss: 25), thresholds: t).health == .critical)
    }

    @Test func offlineIsCriticalAndLabelled() {
        let r = NetworkHealthReading.make(connectivity: .offline, gateway: nil, internet: nil, thresholds: NetworkThresholds())
        #expect(r.health == .critical)
        #expect(MenuBarFormatter.latency(r) == "Offline")
    }

    @Test func timeoutShowsPlaceholder() {
        let r = NetworkHealthReading.make(connectivity: .online, gateway: nil, internet: internet(nil, loss: 100), thresholds: NetworkThresholds())
        #expect(MenuBarFormatter.latency(r) == "--")
        #expect(r.health == .critical)
    }
}
