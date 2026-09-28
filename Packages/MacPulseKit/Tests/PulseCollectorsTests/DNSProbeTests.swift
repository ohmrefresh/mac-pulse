import Foundation
import Testing
@testable import PulseCollectors

@Suite struct DNSProbeTests {
    @Test func encodesQuery() throws {
        let p = try #require(DNSProbe.queryPacket(id: 0xBEEF, name: "apple.com"))
        // Built outside the `#expect` arguments: untyped literals inside the macro blow up the type checker.
        let header: [UInt8] = [0xBE, 0xEF, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        var question: [UInt8] = [5]
        question += "apple".utf8
        question += [3]
        question += "com".utf8
        question += [0, 0, 1, 0, 1]                        // root label, then type A, class IN
        #expect(Array(p.prefix(12)) == header)
        #expect(Array(p.dropFirst(12)) == question)
    }

    @Test func rejectsInvalidNames() {
        #expect(DNSProbe.queryPacket(id: 1, name: "") == nil)
        #expect(DNSProbe.queryPacket(id: 1, name: String(repeating: "a", count: 64) + ".com") == nil)
    }

    @Test func matchesResponsesOnly() {
        let response: [UInt8] = [0xBE, 0xEF, 0x81, 0x80] + Array(repeating: 0, count: 8)
        #expect(DNSProbe.isResponse(response[...], id: 0xBEEF))
        #expect(!DNSProbe.isResponse(response[...], id: 0xBEEE))
        var query = response
        query[2] = 0x01                                    // QR bit clear: a query, not a response
        #expect(!DNSProbe.isResponse(query[...], id: 0xBEEF))
        #expect(!DNSProbe.isResponse(response.prefix(11), id: 0xBEEF))
    }

    @Test func invalidServerFailsFast() async {
        #expect(await DNSProbe.query(server: "not-an-ip") == nil)
    }
}

/// Needs network: `PULSE_NET=1 swift test --filter InternetDNSTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSE_NET"] != nil))
struct InternetDNSTests {
    @Test func queriesSystemResolver() async throws {
        let resolver = try #require(DNSProbe.systemResolver())
        let ms = try #require(await DNSProbe.query(server: resolver))
        print("DNS \(resolver) \(ms) ms")
    }
}
