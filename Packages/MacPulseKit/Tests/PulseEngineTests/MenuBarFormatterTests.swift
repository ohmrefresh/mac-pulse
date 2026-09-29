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
        #expect(MenuBarFormatter.text(MenuBarItem.defaults, inputs) == "CPU 21% · MEM 62% · ↓8.4M ↑1.2M · 18ms")
        #expect(MenuBarFormatter.text([.thermal, .cpu], inputs) == "Serious · CPU 21%")
    }

    @Test func missingReadingsShowPlaceholder() {
        #expect(MenuBarFormatter.text(MenuBarItem.defaults, MenuBarInputs()) == "CPU -- · MEM -- · ↓-- ↑-- · --")
    }

    @Test func temperatureAndGPUSegments() {
        #expect(MenuBarFormatter.text([.temperature, .gpu], MenuBarInputs(cpuCelsius: 48.6, gpuPercent: 12.2)) == "49°C · GPU 12%")
        #expect(MenuBarFormatter.text([.temperature, .gpu], MenuBarInputs()) == "--°C · GPU --")
    }

    @Test func batteryOmittedWithoutBattery() {
        #expect(MenuBarFormatter.text([.cpu, .battery], MenuBarInputs()) == "CPU --")
    }

    private func concern(_ signal: ConcernSignal, _ level: HealthLevel = .warning) -> Concern {
        Concern(signal: signal, level: level, healthy: [])
    }

    @Test func noConcernKeepsChosenOrderUnmarked() {
        let segments = MenuBarFormatter.segments([.cpu, .memory], MenuBarInputs())
        #expect(segments.map(\.item) == [.cpu, .memory])
        #expect(segments.allSatisfy { $0.level == nil })
    }

    @Test func concernLeadsAndIsMarked() {
        let segments = MenuBarFormatter.segments([.cpu, .memory, .network], MenuBarInputs(), concern: concern(.memory))
        #expect(segments.map(\.item) == [.memory, .cpu, .network])
        #expect(segments.map(\.level) == [.warning, nil, nil])
    }

    @Test func concernShownEvenWhenNotChosen() {
        let segments = MenuBarFormatter.segments([.cpu], MenuBarInputs(thermal: .critical), concern: concern(.thermal, .critical))
        #expect(segments.map(\.text) == ["Critical", "CPU --"])
        #expect(segments.first?.level == .critical)
    }

    @Test func batteryConcernNamesTheCondition() {
        #expect(MenuBarFormatter.text([.cpu, .battery], MenuBarInputs(), concern: concern(.battery)) == "BAT Service · CPU --")
    }

    @Test func offlineConcernLeadsWithOffline() {
        let offline = NetworkHealthReading.make(connectivity: .offline, gateway: nil, internet: nil, thresholds: NetworkThresholds())
        let text = MenuBarFormatter.text([.cpu], MenuBarInputs(networkHealth: offline), concern: concern(.internet, .critical))
        #expect(text == "Offline · CPU --")
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

    @Test func segmentsMatchTextAndEveryItemHasASymbol() {
        let inputs = MenuBarInputs()
        let items = MenuBarItem.allCases
        #expect(MenuBarFormatter.segments(items, inputs).map(\.text).joined(separator: MenuBarFormatter.separator)
                == MenuBarFormatter.text(items, inputs))
        #expect(items.allSatisfy { !MenuBarFormatter.symbol(for: $0).isEmpty })
    }
}
