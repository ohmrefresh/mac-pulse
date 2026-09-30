import Testing
import PulseCore
@testable import PulseEngine

@Suite struct PathInsightTests {
    let config = DiagnosticsConfig()   // gateway 100 ms, DNS 200 ms, loss warning 2 %
    let warningMs = 100.0

    private func evaluate(gateway: [Double]? = nil, internet: [Double]? = nil, comparisons: [(String, [Double])] = [],
                          dns: [Double]? = nil) -> (text: String, level: HealthLevel)? {
        PathInsight.evaluate(gateway: gateway.map(LatencyStats.init), internet: internet.map(LatencyStats.init),
                             comparisons: comparisons.map { (name: $0.0, stats: LatencyStats($0.1)) },
                             dns: dns.map(LatencyStats.init), config: config, latencyWarningMs: warningMs)
    }

    @Test func oneSlowComparisonIsNamed() {
        let r = evaluate(gateway: [3, 4], internet: [20, 21], comparisons: [("Google", [20, 300]), ("Quad9", [22, 23])])
        #expect(r?.level == .warning)
        #expect(r?.text == "Only Google is slow — possibly that server or its network.")
    }

    @Test func oneTimingOutComparisonIsNamed() {
        #expect(evaluate(internet: [20, 21], comparisons: [("github.com", [20, .nan])])?.text
                == "Only github.com is slow — possibly that server or its network.")
    }

    @Test func twoSlowComparisonsAreNotBlamedOnEither() {
        #expect(evaluate(gateway: [3], internet: [20], comparisons: [("A", [300]), ("B", [300])]) == nil)
    }

    @Test func slowComparisonWithSlowPrimaryIsNotSingledOut() {
        // Primary also spiking and no gateway data: no rule names the comparison.
        #expect(evaluate(internet: [300], comparisons: [("A", [300]), ("B", [20])]) == nil)
    }

    @Test func existingRulesTakePrecedenceOverTheComparisonRule() {
        let r = evaluate(gateway: [3], internet: [20], comparisons: [("A", [300])], dns: [400])
        #expect(r?.text.hasPrefix("DNS lookups are slow") == true)
    }

    @Test func healthyPathHasNoInsight() {
        #expect(evaluate(gateway: [3, 4, 3], internet: [20, 22, 21], dns: [15, 18]) == nil)
        #expect(evaluate() == nil)
    }

    @Test func slowGatewayPointsAtTheLocalLink() {
        let r = evaluate(gateway: [3, 150, 160], internet: [200, 210])
        #expect(r?.level == .warning)
        #expect(r?.text == "Gateway itself is slow (p95 160 ms), so spikes likely come from your Wi‑Fi or LAN link.")
    }

    /// Every gateway probe timing out gives no p95; the text must not print a made-up number.
    @Test func gatewayLossAloneStillPointsAtTheLocalLink() {
        let r = evaluate(gateway: [.nan, .nan], internet: [20])
        #expect(r?.level == .warning)
        #expect(r?.text == "Gateway is dropping probes (100% loss), so spikes likely come from your Wi‑Fi or LAN link.")
    }

    @Test func slowInternetWithSteadyGatewayPointsUpstream() {
        let r = evaluate(gateway: [3, 4, 5], internet: [20, 250, 30])
        #expect(r?.level == .warning)
        #expect(r?.text == "Spikes appear only past the gateway (LAN steady at 4 ms), so they're likely on the ISP side rather than your Wi‑Fi.")
    }

    @Test func internetTimeoutsWithSteadyGatewayPointUpstream() {
        #expect(evaluate(gateway: [3, 4, 5], internet: [20, .nan, 21])?.text.hasPrefix("Spikes appear only past the gateway") == true)
    }

    @Test func slowInternetWithoutGatewayDataIsNotBlamedOnTheISP() {
        #expect(evaluate(gateway: nil, internet: [250, 260]) == nil)
    }

    @Test func slowDNSIsFlagged() {
        let r = evaluate(gateway: [3], internet: [20], dns: [30, 250])
        #expect(r?.level == .warning)
        #expect(r?.text == "DNS lookups are slow (p95 250 ms), possibly the resolver — try another DNS server.")
    }

    @Test func gatewayRuleWinsOverInternetAndDNS() {
        let r = evaluate(gateway: [150, 150], internet: [300], dns: [400])
        #expect(r?.text.hasPrefix("Gateway itself is slow") == true)
    }
}
