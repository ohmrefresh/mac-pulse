import Testing
@testable import PulseCollectors

@Suite struct HostResolverTests {
    @Test func literalsAreDetected() {
        #expect(HostResolver.isIPLiteral("1.1.1.1"))
        #expect(HostResolver.isIPLiteral("2606:4700:4700::1111"))
        #expect(!HostResolver.isIPLiteral("github.com"))
        #expect(!HostResolver.isIPLiteral("1.1.1"))
    }

    @Test func literalResolvesToItselfWithoutALookup() async {
        #expect(await HostResolver.resolve("8.8.8.8") == ["8.8.8.8"])
    }

    @Test func resolvesLocalhost() async {
        let addresses = await HostResolver.resolve("localhost")
        #expect(!addresses.isEmpty)
        #expect(addresses.allSatisfy { $0 == "127.0.0.1" || $0 == "::1" })
        #expect(Set(addresses).count == addresses.count)       // no duplicates
    }

    @Test func unknownHostResolvesToNothing() async {
        #expect(await HostResolver.resolve("no-such-host.invalid").isEmpty)
    }
}
