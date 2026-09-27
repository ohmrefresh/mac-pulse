import Foundation
import Testing
import PulseCore
@testable import PulseEngine

@Suite struct DiagnosticRulesTests {
    typealias Probe = DiagnosticInput.Probe

    func healthyInput() -> DiagnosticInput {
        var i = DiagnosticInput(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 900))
        i.cpuPeak = 30; i.cpuAverage = 12
        i.memoryPressurePeak = .healthy
        i.thermalPeak = .nominal
        i.diskFreeBytes = 300e9
        i.connectivity = .online
        i.gateway = Probe(address: "192.168.1.1", avgMs: 3, lossPercent: 0)
        i.internet = [Probe(address: "1.1.1.1", avgMs: 18, lossPercent: 0), Probe(address: "8.8.8.8", avgMs: 21, lossPercent: 0)]
        i.dns = ("192.168.1.1", 6)
        return i
    }

    func titles(_ i: DiagnosticInput) -> [String] { DiagnosticRules.evaluate(i).findings.map(\.title) }

    @Test func healthySystemHasNoFindings() {
        #expect(DiagnosticRules.evaluate(healthyInput()).findings.isEmpty)
    }

    @Test func slowDNSWithFastPingBlamesResolver() throws {
        var i = healthyInput()
        i.dns = ("192.168.1.1", 420)
        let f = try #require(DiagnosticRules.evaluate(i).findings.first)
        #expect(f.title == "DNS is slow")
        #expect(f.possibleCause == .likely("the DNS resolver is responding slowly"))
        #expect(f.observed.first == "DNS 192.168.1.1: 420 ms")
    }

    @Test func badGatewayIsLocalProblem() {
        var i = healthyInput()
        i.gateway = Probe(address: "192.168.1.1", avgMs: 180, lossPercent: 20)
        i.internet = i.internet.map { Probe(address: $0.address, avgMs: 200, lossPercent: 20) }
        #expect(titles(i) == ["Local network problem"])      // not also "Internet connection degraded"
    }

    @Test func goodGatewayBadInternetIsUpstream() throws {
        var i = healthyInput()
        i.internet = i.internet.map { Probe(address: $0.address, avgMs: 350, lossPercent: 0) }
        let f = try #require(DiagnosticRules.evaluate(i).findings.first)
        #expect(f.title == "Internet connection degraded")
        #expect(f.health == .critical)
        guard case .likely = f.possibleCause else { Issue.record("expected likely cause"); return }
    }

    @Test func singleSlowTargetIsHedgedAsPossible() throws {
        var i = healthyInput()
        i.internet[0] = Probe(address: "1.1.1.1", avgMs: nil, lossPercent: 100)
        let f = try #require(DiagnosticRules.evaluate(i).findings.first)
        #expect(f.title == "One internet target is slow")
        guard case .possibly = f.possibleCause else { Issue.record("expected possibly"); return }
    }

    @Test func offlineShortCircuitsNetwork() {
        var i = healthyInput()
        i.connectivity = .offline
        i.gateway = nil; i.internet = []; i.dns = ("192.168.1.1", nil)
        #expect(titles(i) == ["No network connection"])
    }

    @Test func highCPUNamesTopContributors() throws {
        var i = healthyInput()
        i.cpuPeak = 94
        i.topProcesses = [("Docker", 48), ("Xcode", 23), ("Chrome", 6), ("Finder", 1)]
        let f = try #require(DiagnosticRules.evaluate(i).findings.first)
        #expect(f.health == .warning)
        #expect(f.observed == ["Peak CPU: 94%", "Average CPU: 12%", "Docker: 48% average", "Xcode: 23% average", "Chrome: 6% average"])
        #expect(f.possibleCause.text == "Likely: load from Docker and other busy processes")
    }

    @Test func memoryPressureWithSwapGrowthIsLikely() throws {
        var i = healthyInput()
        i.memoryPressurePeak = .warning
        i.swapUsedBytes = 4.2 * 1_073_741_824
        i.swapGrowthBytes = 1_073_741_824
        let f = try #require(DiagnosticRules.evaluate(i).findings.first)
        #expect(f.observed.contains("Swap grew by 1.0 GB"))
        guard case .likely = f.possibleCause else { Issue.record("expected likely"); return }
        i.swapGrowthBytes = 0
        guard case .possibly = DiagnosticRules.evaluate(i).findings.first!.possibleCause else { Issue.record("expected possibly"); return }
    }

    @Test func thermalWithLoadSuggestsThrottling() throws {
        var i = healthyInput()
        i.thermalPeak = .serious
        i.cpuPeak = 90
        let f = try #require(DiagnosticRules.evaluate(i).findings.first { $0.area == .thermal })
        #expect(f.possibleCause == .likely("sustained CPU load; macOS may be throttling performance"))
    }

    @Test func lowDiskSeverity() {
        var i = healthyInput()
        i.diskFreeBytes = 8e9
        #expect(DiagnosticRules.evaluate(i).findings.first?.health == .warning)
        i.diskFreeBytes = 3e9
        #expect(DiagnosticRules.evaluate(i).findings.first?.health == .critical)
    }

    @Test func findingsSortedCriticalFirst() {
        var i = healthyInput()
        i.diskFreeBytes = 8e9                      // warning
        i.dns = ("192.168.1.1", nil)              // critical
        #expect(DiagnosticRules.evaluate(i).findings.map(\.health) == [.critical, .warning])
    }

    @Test func everyCauseIsHedged() {
        var i = healthyInput()
        i.cpuPeak = 99; i.memoryPressurePeak = .critical; i.thermalPeak = .critical; i.diskFreeBytes = 1e9
        i.dns = ("x", 900)
        for f in DiagnosticRules.evaluate(i).findings {
            #expect(f.possibleCause.text.hasPrefix("Likely: ") || f.possibleCause.text.hasPrefix("Possibly: "))
            #expect(!f.observed.isEmpty && !f.recommendation.isEmpty)
        }
    }
}
