import Testing
@testable import PulseEngine

@Suite struct CadenceTests {
    /// Runs 1 s ticks from 0 to `seconds` and counts how often each job fired.
    private func counts(seconds: Int, visible: Bool) -> [SamplingJob: Int] {
        var cadence = Cadence(baseInterval: 1)
        cadence.processesVisible = visible
        var counts: [SamplingJob: Int] = [:]
        for t in 0...seconds {
            for job in cadence.due(at: Double(t)) { counts[job, default: 0] += 1 }
        }
        return counts
    }

    @Test func everythingRunsOnFirstTick() {
        var cadence = Cadence()
        #expect(cadence.due(at: 0) == Set(SamplingJob.allCases))
    }

    @Test func backgroundCadences() {
        let c = counts(seconds: 60, visible: false)
        #expect(c[.fast] == 61)
        #expect(c[.power] == 13)          // 0, 5, …, 60
        #expect(c[.processes] == 13)
        #expect(c[.privilegedProcesses] == 13)
        #expect(c[.disk] == 2)            // 0, 60
    }

    @Test func visibleProcessListScansEveryTick() {
        let c = counts(seconds: 10, visible: true)
        #expect(c[.processes] == 11)
        #expect(c[.privilegedProcesses] == 3)   // still ps only every 5 s
    }

    @Test func toleratesTimerJitter() {
        var cadence = Cadence(baseInterval: 1)
        _ = cadence.due(at: 0)
        // A tick that fires slightly early still counts as the next fast tick.
        #expect(cadence.due(at: 0.95).contains(.fast))
        #expect(!cadence.due(at: 1.2).contains(.fast))
    }
}
