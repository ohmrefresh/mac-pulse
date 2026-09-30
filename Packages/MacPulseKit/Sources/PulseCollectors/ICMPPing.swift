import Darwin
import Foundation

/// Unprivileged ICMP echo (`SOCK_DGRAM` + `IPPROTO_ICMP`/`IPPROTO_ICMPV6`, allowed for non-root on macOS).
public enum ICMPPing {
    static let echoRequest: UInt8 = 8
    static let echoReply: UInt8 = 0
    static let echoRequestV6: UInt8 = 128
    static let echoReplyV6: UInt8 = 129

    public enum Family: Sendable, Equatable {
        case ipv4, ipv6

        /// Nil unless `address` is an IP literal.
        public init?(address: String) {
            var v4 = in_addr()
            var v6 = in6_addr()
            let unscoped = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
            if !address.contains("%"), inet_pton(AF_INET, address, &v4) == 1 { self = .ipv4 }
            else if inet_pton(AF_INET6, unscoped, &v6) == 1 { self = .ipv6 }   // "fe80::1%en0" included
            else { return nil }
        }
    }

    public enum Outcome: Sendable, Equatable {
        case reply(Double)
        case timeout
        /// Not sent at all: not an IP literal, no socket, or no route (e.g. IPv6 on an IPv4-only network).
        case sendFailed

        public var milliseconds: Double? { if case .reply(let ms) = self { ms } else { nil } }
    }

    /// Round-trip time in milliseconds, or nil on timeout/error. Blocks for up to `timeout`;
    /// call through `ping(_:timeout:sequence:)` async variant from concurrent code.
    public static func pingBlocking(_ address: String, timeout: TimeInterval, identifier: UInt16, sequence: UInt16) -> Double? {
        probeBlocking(address, timeout: timeout, identifier: identifier, sequence: sequence).milliseconds
    }

    static func probeBlocking(_ address: String, timeout: TimeInterval, identifier: UInt16, sequence: UInt16) -> Outcome {
        guard let family = Family(address: address) else { return .sendFailed }
        var storage = sockaddr_storage()
        let length: Int
        switch family {
        case .ipv4:
            length = MemoryLayout<sockaddr_in>.size
            withUnsafeMutableBytes(of: &storage) { raw in
                var a = sockaddr_in()
                a.sin_len = UInt8(length)
                a.sin_family = sa_family_t(AF_INET)
                inet_pton(AF_INET, address, &a.sin_addr)
                raw.storeBytes(of: a, as: sockaddr_in.self)
            }
        case .ipv6:
            guard let a = ipv6SocketAddress(address) else { return .sendFailed }
            length = MemoryLayout<sockaddr_in6>.size
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: a, as: sockaddr_in6.self) }
        }

        let fd = family == .ipv4 ? socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP) : socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard fd >= 0 else { return .sendFailed }
        defer { close(fd) }

        let packet = echoPacket(identifier: identifier, sequence: sequence, family: family)
        let start = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(length))
                }
            }
        }
        guard sent == packet.count else { return .sendFailed }

        let deadline = start + UInt64(timeout * 1e9)
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timeout }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(max(1, (deadline - now) / 1_000_000))
            guard poll(&pfd, 1, waitMs) > 0 else { return .timeout }
            let received = recv(fd, &buffer, buffer.count, 0)
            guard received > 0 else { return .timeout }
            if isMatchingReply(buffer[..<received], identifier: identifier, sequence: sequence, family: family) {
                return .reply(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            // Another socket's reply or unrelated ICMP: keep waiting until the deadline.
        }
    }

    public static func ping(_ address: String, timeout: TimeInterval = 1, sequence: UInt16) async -> Double? {
        await probe(address, timeout: timeout, sequence: sequence).milliseconds
    }

    /// Like `ping`, but tells a send failure (no route) apart from a timeout, so callers can fall back
    /// from IPv6 to IPv4.
    public static func probe(_ address: String, timeout: TimeInterval = 1, sequence: UInt16) async -> Outcome {
        let identifier = UInt16(truncatingIfNeeded: getpid())
        return await withCheckedContinuation { continuation in
            // Blocking socket I/O stays off the Swift concurrency pool.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: probeBlocking(address, timeout: timeout, identifier: identifier, sequence: sequence))
            }
        }
    }

    /// "addr" or scoped "addr%iface" (needed for link-local fe80::/10) → socket address with
    /// `sin6_scope_id` set. Nil if it is not IPv6 or the scope names no interface on this Mac.
    static func ipv6SocketAddress(_ address: String) -> sockaddr_in6? {
        let parts = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var a = sockaddr_in6()
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        a.sin6_family = sa_family_t(AF_INET6)
        guard inet_pton(AF_INET6, parts[0], &a.sin6_addr) == 1 else { return nil }
        if parts.count == 2 {
            let index = if_nametoindex(parts[1])
            guard index != 0 else { return nil }
            a.sin6_scope_id = index
        }
        return a
    }

    /// ICMPv6 leaves the checksum zero: it covers an IPv6 pseudo-header, and the kernel fills it in.
    static func echoPacket(identifier: UInt16, sequence: UInt16, family: Family = .ipv4) -> [UInt8] {
        var packet: [UInt8] = [family == .ipv4 ? echoRequest : echoRequestV6, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xff),
                               UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        packet += Array("MacPulse".utf8)
        guard family == .ipv4 else { return packet }
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)
        return packet
    }

    /// RFC 1071 Internet checksum.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// macOS delivers datagram ICMP replies with the IPv4 header still attached; tolerate both forms.
    /// ICMPv6 sockets deliver the ICMP message alone.
    static func isMatchingReply(_ data: ArraySlice<UInt8>, identifier: UInt16, sequence: UInt16, family: Family = .ipv4) -> Bool {
        var icmp = data
        if family == .ipv4, let first = data.first, first >> 4 == 4 {
            let headerLength = Int(first & 0x0f) * 4
            guard data.count >= headerLength + 8 else { return false }
            icmp = data.dropFirst(headerLength)
        }
        guard icmp.count >= 8 else { return false }
        let b = Array(icmp.prefix(8))
        return b[0] == (family == .ipv4 ? echoReply : echoReplyV6)
            && UInt16(b[4]) << 8 | UInt16(b[5]) == identifier
            && UInt16(b[6]) << 8 | UInt16(b[7]) == sequence
    }
}

/// Packet loss over the most recent probes to one target.
public struct LossWindow: Sendable, Equatable {
    public let capacity: Int
    private var results: [Bool] = []

    public init(capacity: Int = 12) {
        self.capacity = capacity
    }

    public mutating func record(success: Bool) {
        results.append(success)
        if results.count > capacity { results.removeFirst(results.count - capacity) }
    }

    /// Nil until at least one probe has been recorded.
    public var lossPercent: Double? {
        guard !results.isEmpty else { return nil }
        return Double(results.filter { !$0 }.count) / Double(results.count) * 100
    }
}
