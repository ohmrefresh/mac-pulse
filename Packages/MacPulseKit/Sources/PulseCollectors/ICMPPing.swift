import Darwin
import Foundation

/// Unprivileged ICMP echo (`SOCK_DGRAM` + `IPPROTO_ICMP`, allowed for non-root on macOS). IPv4 only.
public enum ICMPPing {
    static let echoRequest: UInt8 = 8
    static let echoReply: UInt8 = 0

    /// Round-trip time in milliseconds, or nil on timeout/error. Blocks for up to `timeout`;
    /// call through `ping(_:timeout:sequence:)` async variant from concurrent code.
    public static func pingBlocking(_ address: String, timeout: TimeInterval, identifier: UInt16, sequence: UInt16) -> Double? {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let packet = echoPacket(identifier: identifier, sequence: sequence)
        let start = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return nil }

        let deadline = start + UInt64(timeout * 1e9)
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(max(1, (deadline - now) / 1_000_000))
            guard poll(&pfd, 1, waitMs) > 0 else { return nil }
            let received = recv(fd, &buffer, buffer.count, 0)
            guard received > 0 else { return nil }
            if isMatchingReply(buffer[..<received], identifier: identifier, sequence: sequence) {
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            }
            // Another socket's reply or unrelated ICMP: keep waiting until the deadline.
        }
    }

    public static func ping(_ address: String, timeout: TimeInterval = 1, sequence: UInt16) async -> Double? {
        let identifier = UInt16(truncatingIfNeeded: getpid())
        return await withCheckedContinuation { continuation in
            // Blocking socket I/O stays off the Swift concurrency pool.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: pingBlocking(address, timeout: timeout, identifier: identifier, sequence: sequence))
            }
        }
    }

    static func echoPacket(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [echoRequest, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xff),
                               UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        packet += Array("MacPulse".utf8)
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
    static func isMatchingReply(_ data: ArraySlice<UInt8>, identifier: UInt16, sequence: UInt16) -> Bool {
        var icmp = data
        if let first = data.first, first >> 4 == 4 {
            let headerLength = Int(first & 0x0f) * 4
            guard data.count >= headerLength + 8 else { return false }
            icmp = data.dropFirst(headerLength)
        }
        guard icmp.count >= 8 else { return false }
        let b = Array(icmp.prefix(8))
        return b[0] == echoReply
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
