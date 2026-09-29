import Testing
import PulseCore
@testable import PulseEngine

@Suite struct ConcernTests {
    @Test func allHealthyHasNoConcern() {
        let levels = Dictionary(uniqueKeysWithValues: ConcernSignal.allCases.map { ($0, HealthLevel.healthy) })
        #expect(Concern.current(levels) == nil)
        #expect(Concern.current([:]) == nil)
    }

    @Test func worstWins() throws {
        let c = try #require(Concern.current([.cpu: .warning, .memory: .healthy, .thermal: .critical]))
        #expect(c.signal == .thermal)
        #expect(c.level == .critical)
    }

    @Test func tieGoesToReadingOrder() throws {
        let c = try #require(Concern.current([.thermal: .warning, .memory: .warning, .internet: .warning]))
        #expect(c.signal == .memory)
    }

    @Test func unknownIsNeitherConcernNorHealthy() throws {
        let c = try #require(Concern.current([.cpu: .unknown, .memory: .warning, .internet: .healthy, .thermal: .healthy]))
        #expect(c.signal == .memory)
        #expect(c.healthy == [.internet, .thermal])
        #expect(Concern.current([.cpu: .unknown]) == nil)
    }
}
