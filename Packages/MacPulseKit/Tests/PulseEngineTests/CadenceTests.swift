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

    @Test func gpuSpeedsUpOnlyWhileThePerformancePageIsVisible() {
        func gpuTicks(visible: Bool) -> Int {
            var cadence = Cadence(baseInterval: 1)
            cadence.performanceVisible = visible
            return (0...60).reduce(0) { $0 + (cadence.due(at: Double($1)).contains(.gpu) ? 1 : 0) }
        }
        #expect(gpuTicks(visible: false) == 13)   // 0, 5, …, 60
        #expect(gpuTicks(visible: true) == 61)
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

    @Test func sensorsEveryMinuteUnlessVisible() {
        #expect(counts(seconds: 120, visible: false)[.sensors] == 3)     // 0, 60, 120
        var cadence = Cadence(baseInterval: 1)
        cadence.sensorsVisible = true
        var n = 0
        for t in 0...10 where cadence.due(at: Double(t)).contains(.sensors) { n += 1 }
        #expect(n == 3)                                                  // 0, 5, 10
    }

    @Test func toleratesTimerJitter() {
        var cadence = Cadence(baseInterval: 1)
        _ = cadence.due(at: 0)
        // A tick that fires slightly early still counts as the next fast tick.
        #expect(cadence.due(at: 0.95).contains(.fast))
        #expect(!cadence.due(at: 1.2).contains(.fast))
    }

    @Test func menuBarTemperatureRefreshesEvery15Seconds() {
        var cadence = Cadence(baseInterval: 1)
        cadence.sensorsInMenuBar = true
        var n = 0
        for t in 0...30 where cadence.due(at: Double(t)).contains(.sensors) { n += 1 }
        #expect(n == 3)                                                   // 0, 15, 30
    }

    @Test func expediteMakesJobDueNow() {
        var cadence = Cadence(baseInterval: 1)
        _ = cadence.due(at: 0)
        #expect(!cadence.due(at: 1).contains(.disk))
        cadence.expedite(.disk)
        #expect(cadence.due(at: 2).contains(.disk))
        #expect(!cadence.due(at: 3).contains(.disk))                      // back to its 60 s cadence
    }

    /// Wi‑Fi details tick every 5 s; the Sampler reads them only while the Network page is visible.
    @Test func wifiRunsEveryFiveSeconds() {
        var cadence = Cadence(baseInterval: 1)
        let n = (0...60).reduce(0) { $0 + (cadence.due(at: Double($1)).contains(.wifi) ? 1 : 0) }
        #expect(n == 13)
    }
}
