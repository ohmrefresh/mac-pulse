import Testing
@testable import PulseCollectors

@Suite struct CPUUsageTests {
    @Test func computesTotalAndPerCore() throws {
        let before = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0),
                      CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let after = [CPUTicks(user: 150, system: 75, idle: 875, nice: 0),   // 75 busy / 100
                     CPUTicks(user: 0, system: 0, idle: 1100, nice: 0)]     // 0 busy / 100
        let reading = try #require(CPUUsage.reading(from: before, to: after))
        #expect(reading.perCorePercent == [75, 0])
        #expect(reading.totalPercent == 37.5)
    }

    @Test func handlesCounterWrap() throws {
        let before = [CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 19, nice: 0)]
        let after = [CPUTicks(user: 10, system: 0, idle: 0, nice: 0)]   // 20 busy, 20 idle
        let reading = try #require(CPUUsage.reading(from: before, to: after))
        #expect(reading.totalPercent == 50)
    }

    @Test func mismatchedCoreCountReturnsNil() {
        let one = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        #expect(CPUUsage.reading(from: one, to: one + one) == nil)
    }

    @Test func idleIntervalIsZero() throws {
        let t = [CPUTicks(user: 5, system: 5, idle: 5, nice: 0)]
        #expect(try #require(CPUUsage.reading(from: t, to: t)).totalPercent == 0)
    }

    @Test func liveCollectorPrimesThenReads() throws {
        var collector = CPUCollector()
        let first = collector.sample()
        let second = collector.sample()
        #expect(first == nil)
        let reading = try #require(second)
        #expect((0...100).contains(reading.totalPercent))
        #expect(!reading.perCorePercent.isEmpty)
        #expect(CPUCollector.processorName()?.isEmpty == false)
    }
}

@Suite struct MemoryTests {
    @Test func pressureLevels() {
        #expect(MemoryCollector.pressure(kernelLevel: 1) == .normal)
        #expect(MemoryCollector.pressure(kernelLevel: 2) == .warning)
        #expect(MemoryCollector.pressure(kernelLevel: 4) == .critical)
        #expect(MemoryCollector.pressure(kernelLevel: 3) == nil)
    }

    @Test func liveReadingIsPlausible() throws {
        let reading = try #require(MemoryCollector().sample())
        #expect(reading.totalBytes > 0)
        #expect(reading.usedBytes > 0)
        #expect(reading.usedBytes <= reading.totalBytes)
        #expect(reading.pressure != nil)
    }
}
