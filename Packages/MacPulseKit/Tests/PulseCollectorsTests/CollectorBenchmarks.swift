import Foundation
import Testing
@testable import PulseCollectors

/// Per-call cost budgets (plan decision 12). Timing-sensitive, so opt-in and meant for release builds:
/// `PULSE_BENCH=1 swift test -c release --filter CollectorBenchmarks`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSE_BENCH"] != nil))
struct CollectorBenchmarks {
    private func averageMs(_ iterations: Int, _ body: () -> Void) -> Double {
        let duration = ContinuousClock().measure { for _ in 0..<iterations { body() } }
        let ms = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return ms / Double(iterations)
    }

    @Test func fastCollectorsUnderHalfMillisecond() {
        var cpu = CPUCollector()
        let memory = MemoryCollector()
        var network = NetworkCollector()
        let costs = [
            ("cpu", averageMs(200) { _ = cpu.sample() }),
            ("memory", averageMs(200) { _ = memory.sample() }),
            ("network", averageMs(200) { _ = network.sample() }),
        ]
        for (name, ms) in costs {
            print(String(format: "BENCH %@ %.3f ms", name, ms))
            #expect(ms < 0.5, "\(name) took \(ms) ms")
        }
    }

    @Test func processScanUnder15Milliseconds() {
        var collector = ProcessCollector()
        let direct = averageMs(20) { _ = collector.sample(refreshPrivileged: false) }
        let withPS = averageMs(5) { _ = collector.sample(refreshPrivileged: true) }
        print(String(format: "BENCH processes direct %.3f ms, with ps %.3f ms (wall, mostly waiting on child)", direct, withPS))
        #expect(direct < 15)
    }
}
