import Darwin
import Foundation
import SystemConfiguration

/// Times a direct UDP DNS query to the system's resolver. Going through getaddrinfo would mostly
/// hit mDNSResponder's cache and measure nothing; querying the resolver shows when *it* is slow.
public enum DNSProbe {
    /// A popular name the resolver almost certainly has cached, so the result reflects the
    /// resolver's own responsiveness rather than upstream recursion.
    public static let defaultQueryName = "apple.com"

    /// First IPv4 resolver from the active network configuration, e.g. "192.168.1.1".
    public static func systemResolver() -> String? {
        let store = SCDynamicStoreCreate(nil, "MacPulse" as CFString, nil, nil)
        guard let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dict["ServerAddresses"] as? [String] else { return nil }
        return servers.first { var a = in_addr(); return inet_pton(AF_INET, $0, &a) == 1 }
    }

    /// Round-trip milliseconds, or nil on timeout/error.
    public static func queryBlocking(server: String, name: String, timeout: TimeInterval, id: UInt16) -> Double? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, server, &address.sin_addr) == 1, let packet = queryPacket(id: id, name: name) else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }

        let start = DispatchTime.now().uptimeNanoseconds
        guard packet.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == packet.count else { return nil }
        let deadline = start + UInt64(timeout * 1e9)
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(max(1, (deadline - now) / 1_000_000))) > 0 else { return nil }
            let received = recv(fd, &buffer, buffer.count, 0)
            guard received > 0 else { return nil }
            if isResponse(buffer[..<received], id: id) {
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            }
        }
    }

    public static func query(server: String, name: String = defaultQueryName, timeout: TimeInterval = 2) async -> Double? {
        let id = UInt16.random(in: .min ... .max)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: queryBlocking(server: server, name: name, timeout: timeout, id: id))
            }
        }
    }

    /// Standard query, recursion desired, one A/IN question. Nil for an invalid name.
    static func queryPacket(id: UInt16, name: String) -> [UInt8]? {
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count) else { return nil }
            packet.append(UInt8(bytes.count))
            packet += bytes
        }
        guard packet.count > 12 else { return nil }
        packet += [0, 0, 1, 0, 1]
        return packet
    }

    /// Any response (including NXDOMAIN/SERVFAIL) proves the resolver answered.
    static func isResponse(_ data: ArraySlice<UInt8>, id: UInt16) -> Bool {
        guard data.count >= 12 else { return false }
        let b = Array(data.prefix(3))
        return UInt16(b[0]) << 8 | UInt16(b[1]) == id && b[2] & 0x80 != 0
    }
}
