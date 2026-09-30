import Foundation
import Testing
import PulseCore

@Suite struct ProbeTargetTests {
    @Test func validatesAddressForms() {
        #expect(ProbeTarget.kind(of: "1.1.1.1") == .ipv4)
        #expect(ProbeTarget.kind(of: "2606:4700:4700::1111") == .ipv6)
        #expect(ProbeTarget.kind(of: "::1") == .ipv6)
        #expect(ProbeTarget.kind(of: "github.com") == .hostname)
        #expect(ProbeTarget.kind(of: "localhost") == .hostname)
        #expect(ProbeTarget.kind(of: "my-router.lan") == .hostname)
        #expect(ProbeTarget.kind(of: "  1.1.1.1 ") == .ipv4)          // surrounding whitespace is ignored
    }

    /// A link-local address (fe80::/10) is only reachable through one interface: without a scope
    /// every send fails, so it would read as permanent loss.
    @Test func linkLocalNeedsAScope() {
        #expect(ProbeTarget.kind(of: "fe80::1") == nil)
        #expect(ProbeTarget.kind(of: "FE80::abcd") == nil)
        #expect(ProbeTarget.kind(of: "febf::1") == nil)                 // still inside fe80::/10
        #expect(ProbeTarget.kind(of: "fe80::1%en0") == .ipv6)
        #expect(ProbeTarget.kind(of: "fe80::1%") == nil)                // empty scope
        #expect(ProbeTarget.kind(of: "1.1.1.1%en0") == nil)             // scopes are IPv6 only
        #expect(ProbeTarget.kind(of: "fec0::1") == .ipv6)               // not link-local
        #expect(ProbeTarget.kind(of: "2606:4700:4700::1111") == .ipv6)
    }

    @Test func rejectsJunk() {
        for junk in ["", " ", "1.1.1", "256.1.1.1", "-bad.com", "bad-.com", "a..b", "exa mple.com",
                     "under_score.com", "http://x.com", "x.com/", String(repeating: "a", count: 64) + ".com"] {
            #expect(ProbeTarget.kind(of: junk) == nil, "\(junk)")
        }
        #expect(!ProbeTarget("nope nope").isValid)
        #expect(ProbeTarget("8.8.8.8").isValid)
    }

    @Test func codableRoundTrip() throws {
        let t = [ProbeTarget("1.1.1.1", label: "Cloudflare"), ProbeTarget("github.com")]
        let back = try JSONDecoder().decode([ProbeTarget].self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }

    @Test func defaultsAndMaxCount() {
        #expect(ProbeTargets.defaults.map(\.address) == ["1.1.1.1", "8.8.8.8"])
        #expect(ProbeTargets.maxCount == 4)
    }

    @Test func migrationKeepsTheOldPingHostFirst() {
        #expect(ProbeTargets.migrated(from: "1.1.1.1").map(\.address) == ["1.1.1.1", "8.8.8.8"])
        #expect(ProbeTargets.migrated(from: "8.8.8.8").map(\.address) == ["8.8.8.8", "1.1.1.1"])
        #expect(ProbeTargets.migrated(from: "9.9.9.9").map(\.address) == ["9.9.9.9", "8.8.8.8"])
        #expect(ProbeTargets.migrated(from: "not valid") == ProbeTargets.defaults)
    }

    @Test func sanitizedTrimsDedupesAndCaps() {
        let raw = [ProbeTarget(" 1.1.1.1 ", label: "  "), ProbeTarget("junk!"), ProbeTarget("GitHub.com", label: "Git"),
                   ProbeTarget("github.com"), ProbeTarget("1.1.1.1"), ProbeTarget("8.8.8.8"),
                   ProbeTarget("9.9.9.9"), ProbeTarget("::1")]
        let s = ProbeTargets.sanitized(raw)
        #expect(s.map(\.address) == ["1.1.1.1", "GitHub.com", "8.8.8.8", "9.9.9.9"])
        #expect(s[0].label == nil)                 // blank label dropped
        #expect(s[1].label == "Git")
    }

    @Test func sanitizedNeverReturnsAnEmptyList() {
        #expect(ProbeTargets.sanitized([]) == ProbeTargets.defaults)
        #expect(ProbeTargets.sanitized([ProbeTarget("??")]) == ProbeTargets.defaults)
    }

    @Test func displayNamePrefersTheLabel() {
        #expect(ProbeTarget("1.1.1.1", label: "Cloudflare").displayName == "Cloudflare")
        #expect(ProbeTarget("1.1.1.1").displayName == "1.1.1.1")
    }
}
