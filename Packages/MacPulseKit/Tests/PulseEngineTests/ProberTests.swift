import Foundation
import Testing
import PulseCore
import PulseCollectors
@testable import PulseEngine

@Suite struct ProberTests {
    /// Fake network: fixed resolutions and per-address outcomes, recording what was pinged.
    final class FakeNet: @unchecked Sendable {
        let lock = NSLock()
        var resolutions: [String: [String]] = [:]
        var outcomes: [String: ICMPPing.Outcome] = [:]
        private(set) var pinged: [(address: String, sequence: UInt16)] = []
        private(set) var resolveCount = 0

        func resolve(_ host: String) -> [String] {
            lock.withLock { resolveCount += 1; return resolutions[host] ?? (HostResolver.isIPLiteral(host) ? [host] : []) }
        }
        func ping(_ address: String, _ sequence: UInt16) -> ICMPPing.Outcome {
            lock.withLock { pinged.append((address, sequence)); return outcomes[address] ?? .reply(10) }
        }
    }

    func prober(_ net: FakeNet, _ targets: [ProbeTarget]) -> Prober {
        Prober(targets: targets, ping: { net.ping($0, $1) }, resolve: { net.resolve($0) })
    }

    @Test func probesEveryTargetInListOrder() async {
        let net = FakeNet()
        let p = prober(net, [ProbeTarget("1.1.1.1"), ProbeTarget("8.8.8.8", label: "Google"), ProbeTarget("9.9.9.9")])
        let r = await p.probeInternet(now: 0)
        #expect(r.map(\.address) == ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
        #expect(r[1].label == "Google" && r[1].host == "8.8.8.8")
        #expect(r.allSatisfy { $0.latencyMs == 10 && $0.lossPercent == 0 })
    }

    @Test func sequenceNumbersNeverCollideAcrossRounds() async {
        let net = FakeNet()
        let targets = ["1.1.1.1", "8.8.8.8", "9.9.9.9", "4.4.4.4"].map { ProbeTarget($0) }
        let p = prober(net, targets)
        for round in 0..<3 { _ = await p.probeInternet(now: Double(round) * 5) }
        let sequences = net.pinged.map(\.sequence)
        #expect(sequences.count == 12)
        #expect(Set(sequences).count == 12)
        // The gateway takes the slot after the targets, so it never shares a sequence either.
        let gateway = Prober.sequences(base: 100, targetCount: 4)
        #expect(gateway.targets == [100, 101, 102, 103] && gateway.gateway == 104 && gateway.next == 105)
    }

    @Test func hostnamesUseTheFirstResolvedAddress() async {
        let net = FakeNet()
        net.resolutions["example.com"] = ["93.184.216.34", "93.184.216.35"]
        let r = await prober(net, [ProbeTarget("example.com")]).probeInternet(now: 0)
        #expect(r.first?.address == "93.184.216.34" && r.first?.host == "example.com")
    }

    @Test func ipv6WithoutARouteFallsBackToIPv4() async {
        let net = FakeNet()
        net.resolutions["dual.test"] = ["2001:db8::1", "192.0.2.1"]
        net.outcomes["2001:db8::1"] = .sendFailed
        net.outcomes["192.0.2.1"] = .reply(22)
        let r = await prober(net, [ProbeTarget("dual.test")]).probeInternet(now: 0)
        #expect(r.first?.address == "192.0.2.1" && r.first?.latencyMs == 22)
    }

    @Test func unresolvedTargetIsNotLoss() async {
        let net = FakeNet()
        let p = prober(net, [ProbeTarget("1.1.1.1"), ProbeTarget("no-such.invalid")])
        let r = await p.probeInternet(now: 0)
        #expect(r[1].unresolved && r[1].latencyMs == nil && r[1].lossPercent == nil)
        #expect(r[1].address == "no-such.invalid")
        #expect(!net.pinged.contains { $0.address == "no-such.invalid" })
    }

    @Test func resolutionIsCachedForFiveMinutes() async {
        let net = FakeNet()
        net.resolutions["example.com"] = ["93.184.216.34"]
        let p = prober(net, [ProbeTarget("example.com")])
        _ = await p.probeInternet(now: 0)
        _ = await p.probeInternet(now: 299)
        #expect(net.resolveCount == 1)
        _ = await p.probeInternet(now: 300)
        #expect(net.resolveCount == 2)
        await p.networkChanged()
        _ = await p.probeInternet(now: 301)
        #expect(net.resolveCount == 3)
    }

    @Test func reconfiguringKeepsLossWindowsOfRemainingTargets() async {
        let net = FakeNet()
        net.outcomes["8.8.8.8"] = .timeout
        let p = prober(net, [ProbeTarget("1.1.1.1"), ProbeTarget("8.8.8.8")])
        _ = await p.probeInternet(now: 0)
        await p.configure(targets: [ProbeTarget("8.8.8.8"), ProbeTarget("9.9.9.9")], thresholds: NetworkThresholds())
        net.outcomes["8.8.8.8"] = .reply(10)
        let r = await p.probeInternet(now: 5)
        #expect(r[0].lossPercent == 50)       // one timeout kept from before, one reply now
        #expect(r[1].lossPercent == 0)
        await p.configure(targets: [ProbeTarget("1.1.1.1")], thresholds: NetworkThresholds())
        await p.configure(targets: [ProbeTarget("8.8.8.8")], thresholds: NetworkThresholds())
        #expect(await p.probeInternet(now: 10)[0].lossPercent == 0)   // dropped once, so its history is gone
    }

    /// Names resolve in parallel on a refresh: four slow lookups cost about one, not four.
    @Test func hostnamesResolveInParallel() async {
        let targets = ["a.test", "b.test", "c.test", "d.test"].map { ProbeTarget($0) }
        let p = Prober(targets: targets, ping: { _, _ in .reply(1) }, resolve: { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return ["192.0.2.1"]
        })
        let elapsed = await ContinuousClock().measure { _ = await p.probeInternet(now: 0) }
        #expect(elapsed < .milliseconds(900))
    }
}
