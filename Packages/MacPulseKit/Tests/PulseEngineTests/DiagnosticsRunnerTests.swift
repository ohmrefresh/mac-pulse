import Foundation
import Testing
import PulseCore
import PulseStore
@testable import PulseEngine

@Suite struct DiagnosticsRunnerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func averageCPUAcrossScansCountsAbsenceAsZero() {
        func s(_ t: Double, _ name: String, _ cpu: Double) -> ProcessSample {
            ProcessSample(time: t0.addingTimeInterval(t), pid: 1, name: name, cpuPercent: cpu, memoryBytes: 0)
        }
        let samples = [s(0, "Docker", 60), s(0, "Xcode", 20),
                       s(5, "Docker", 40),                      // Xcode absent: counts as 0
                       s(10, "Docker", 50), s(10, "helper", 1), s(10, "helper", 1)]
        let avg = HistoryFacts.averageCPU(samples)
        #expect(avg.map(\.name) == ["Docker", "Xcode"])        // helper averages 0.67% → dropped
        #expect(avg[0].cpu == 50)
        #expect(abs(avg[1].cpu - 20.0 / 3) < 1e-9)
    }

    @Test func historyFactsFromStore() throws {
        let store = try HistoryStore(url: nil)
        func m(_ k: MetricKind, _ v: Double, _ t: Double) -> MetricSample { MetricSample(kind: k, value: v, timestamp: t0.addingTimeInterval(t)) }
        try store.write(samples: [m(.cpuPercent, 20, 0), m(.cpuPercent, 94, 1), m(.memoryPressure, 1, 0), m(.memoryPressure, 2, 1),
                                  m(.swapUsedBytes, 1e9, 0), m(.swapUsedBytes, 3e9, 1), m(.thermalState, 0, 0), m(.thermalState, 2, 1)],
                        processes: [], now: t0.addingTimeInterval(2), retention: .thirtyDays)
        var input = DiagnosticInput(from: t0, to: t0.addingTimeInterval(2))
        try HistoryFacts.load(store, from: t0, to: t0.addingTimeInterval(2)).apply(to: &input)
        #expect(input.cpuPeak == 94 && input.cpuAverage == 57)
        #expect(input.memoryPressurePeak == .warning)
        #expect(input.swapGrowthBytes == 2e9 && input.swapUsedBytes == 3e9)
        #expect(input.thermalPeak == .serious)
    }
}

/// Needs network: `PULSE_NET=1 swift test --filter LiveDiagnosticsTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSE_NET"] != nil))
struct LiveDiagnosticsTests {
    @Test func fullRunCompletesQuickly() async {
        let clock = ContinuousClock()
        var report: DiagnosticReport?
        let elapsed = await clock.measure {
            report = await DiagnosticsRunner.run(history: nil, live: .init(memoryUsedPercent: 60, diskFreeBytes: 300e9,
                                                                          primaryTarget: "1.1.1.1", cpuFallback: [10, 20]))
        }
        print("DIAG took \(elapsed); findings: \(report?.findings.map(\.title) ?? [])")
        #expect(elapsed < .seconds(15))
    }
}
