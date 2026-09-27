import Foundation
import Testing
@testable import PulseCollectors

@Suite struct NetworkConfigTests {
    @Test func vpnFromPrimaryOrRoutableTunnelAddress() {
        #expect(NetworkConfigCollector.vpnInterfaces(primary: "en0", ipv4ByInterface: ["en0": ["192.168.1.5"]]).isEmpty)
        #expect(NetworkConfigCollector.vpnInterfaces(primary: "utun4", ipv4ByInterface: [:]) == ["utun4"])
        // Split tunnel: primary stays en0, but a tunnel carries a routable address.
        #expect(NetworkConfigCollector.vpnInterfaces(primary: "en0",
                                                      ipv4ByInterface: ["en0": ["192.168.1.5"], "utun6": ["10.8.0.2"]]) == ["utun6"])
        // System tunnels with only link-local IPv4 are not VPNs.
        #expect(NetworkConfigCollector.vpnInterfaces(primary: "en0", ipv4ByInterface: ["utun0": ["169.254.3.1"]]).isEmpty)
    }

    @Test func parsesEnabledProxiesOnly() {
        let d: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "proxy.corp", "HTTPPort": 8080,
                                "HTTPSEnable": 0, "HTTPSProxy": "ignored", "HTTPSPort": 443,
                                "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://wpad/proxy.pac"]
        #expect(NetworkConfigCollector.parseProxies(d) == [.init(kind: .http, target: "proxy.corp:8080"),
                                                           .init(kind: .autoConfig, target: "http://wpad/proxy.pac")])
        #expect(NetworkConfigCollector.parseProxies([:]).isEmpty)
    }

    @Test func parsesCloudflareTrace() {
        let trace = "fl=123\nh=1.1.1.1\nip=203.0.113.7\nts=1.2\nloc=TH\nwarp=off\n"
        #expect(PublicIPLookup.parse(trace) == .init(ip: "203.0.113.7", country: "TH"))
        #expect(PublicIPLookup.parse("fl=1\n") == nil)
    }

    @Test func liveSampleIsConsistent() {
        let r = NetworkConfigCollector.sample()
        #expect(r.vpnActive == !r.vpnInterfaces.isEmpty)
    }
}

/// Needs network: `PULSE_NET=1 swift test --filter LivePublicIPTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSE_NET"] != nil))
struct LivePublicIPTests {
    @Test func fetchesPublicIP() async throws {
        let r = try #require(await PublicIPLookup.fetch())
        print("PUBLICIP \(r.ip) \(r.country ?? "-")")
    }
}
