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
