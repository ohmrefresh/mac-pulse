import Foundation
import Testing
@testable import PulseCollectors

@Suite struct ICMPPingTests {
    @Test func checksumOfPacketVerifiesToZero() {
        let packet = ICMPPing.echoPacket(identifier: 0x1234, sequence: 7)
        // Summing a packet including its own checksum yields 0 after complement.
        #expect(ICMPPing.checksum(packet) == 0)
        #expect(packet[0] == 8 && packet[4] == 0x12 && packet[5] == 0x34 && packet[7] == 7)
    }

    @Test func checksumHandlesOddLength() {
        #expect(ICMPPing.checksum([0x01]) == ~UInt16(0x0100))
    }

    @Test func matchesReplyWithAndWithoutIPHeader() {
        let icmp: [UInt8] = [0, 0, 0, 0, 0x12, 0x34, 0, 7]
        let ipHeader: [UInt8] = [0x45] + Array(repeating: 0, count: 19)
        #expect(ICMPPing.isMatchingReply(icmp[...], identifier: 0x1234, sequence: 7))
        #expect(ICMPPing.isMatchingReply((ipHeader + icmp)[...], identifier: 0x1234, sequence: 7))
        #expect(!ICMPPing.isMatchingReply(icmp[...], identifier: 0x1234, sequence: 8))
        #expect(!ICMPPing.isMatchingReply(([8] + icmp.dropFirst())[...], identifier: 0x1234, sequence: 7)) // request, not reply
    }

    /// ICMPv6 echo: type 128, the kernel fills in the checksum (it covers a pseudo-header we don't build).
    @Test func echoPacketV6() {
        let packet = ICMPPing.echoPacket(identifier: 0x1234, sequence: 7, family: .ipv6)
        #expect(packet[0] == 128 && packet[1] == 0 && packet[2] == 0 && packet[3] == 0)
        #expect(packet[4] == 0x12 && packet[5] == 0x34 && packet[6] == 0 && packet[7] == 7)
    }

    /// ICMPv6 datagram sockets deliver the ICMP message without the IPv6 header.
    @Test func matchesV6Reply() {
        let reply: [UInt8] = [129, 0, 0xab, 0xcd, 0x12, 0x34, 0, 7]
        #expect(ICMPPing.isMatchingReply(reply[...], identifier: 0x1234, sequence: 7, family: .ipv6))
        #expect(!ICMPPing.isMatchingReply(reply[...], identifier: 0x1234, sequence: 8, family: .ipv6))
        #expect(!ICMPPing.isMatchingReply(([128] + reply.dropFirst())[...], identifier: 0x1234, sequence: 7, family: .ipv6))
        #expect(!ICMPPing.isMatchingReply(reply[...], identifier: 0x1234, sequence: 7, family: .ipv4))  // 129 is not an ICMPv4 reply
    }

    @Test func scopedLinkLocalSetsTheScopeID() throws {
        let a = try #require(ICMPPing.ipv6SocketAddress("fe80::1%lo0"))
        #expect(a.sin6_scope_id == if_nametoindex("lo0") && a.sin6_scope_id != 0)
        #expect(a.sin6_family == sa_family_t(AF_INET6))
        #expect(ICMPPing.ipv6SocketAddress("fe80::1%nosuchif9") == nil)
        #expect(ICMPPing.Family(address: "fe80::1%lo0") == .ipv6)
        #expect(HostResolver.isIPLiteral("fe80::1%lo0"))
    }

    @Test func globalIPv6ParsesWithoutAScope() throws {
        let a = try #require(ICMPPing.ipv6SocketAddress("2606:4700:4700::1111"))
        #expect(a.sin6_scope_id == 0)
        #expect(a.sin6_addr.__u6_addr.__u6_addr8.0 == 0x26)
    }

    /// lo0 carries fe80::1 on macOS; tolerate hosts where it does not.
    @Test func pingsScopedLinkLocalLoopback() async {
        let outcome = await ICMPPing.probe("fe80::1%lo0", timeout: 1, sequence: 4)
        if case .reply(let rtt) = outcome { #expect(rtt >= 0 && rtt < 1_000) }
    }

    @Test func familyOfAnAddress() {
        #expect(ICMPPing.Family(address: "1.1.1.1") == .ipv4)
        #expect(ICMPPing.Family(address: "::1") == .ipv6)
        #expect(ICMPPing.Family(address: "github.com") == nil)
    }

    /// Tolerates Macs or CI hosts without IPv6 loopback.
    @Test func pingsV6Loopback() async {
        switch await ICMPPing.probe("::1", timeout: 1, sequence: 2) {
        case .reply(let rtt): #expect(rtt >= 0 && rtt < 1_000)
        case .timeout, .sendFailed: break
        }
    }

    @Test func unparseableAddressFailsToSend() async {
        #expect(await ICMPPing.probe("github.com", timeout: 1, sequence: 3) == .sendFailed)
    }

    @Test func pingsLoopback() async throws {
        let rtt = try #require(await ICMPPing.ping("127.0.0.1", timeout: 1, sequence: 1))
        #expect(rtt >= 0 && rtt < 1_000)
    }

    @Test func invalidAddressFailsFast() async {
        #expect(await ICMPPing.ping("not-an-ip", sequence: 1) == nil)
    }
}

@Suite struct LossWindowTests {
    @Test func rollingLoss() {
        var w = LossWindow(capacity: 4)
        #expect(w.lossPercent == nil)
        w.record(success: true)
        w.record(success: false)
        #expect(w.lossPercent == 50)
        for _ in 0..<4 { w.record(success: true) }   // the failure ages out
        #expect(w.lossPercent == 0)
    }
}

/// Needs internet access: `PULSE_NET=1 swift test --filter InternetPingTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSE_NET"] != nil))
struct InternetPingTests {
    @Test func pingsCloudflareAndGateway() async throws {
        let internet = try #require(await ICMPPing.ping("1.1.1.1", timeout: 2, sequence: 1))
        print("PING 1.1.1.1 \(internet) ms")
        let gateway = try #require(NetworkCollector.gatewayAddress())
        let gatewayRTT = try #require(await ICMPPing.ping(gateway, timeout: 2, sequence: 2))
        print("PING gateway \(gateway) \(gatewayRTT) ms")
    }
}
