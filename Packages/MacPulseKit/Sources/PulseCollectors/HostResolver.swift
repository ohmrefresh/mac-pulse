import Darwin
import Foundation
import os

/// Turns a user-typed internet target into IP addresses, via the system resolver (`getaddrinfo`).
public enum HostResolver {
    public static func isIPLiteral(_ host: String) -> Bool {
        ICMPPing.Family(address: host) != nil
    }

    /// Addresses in the system's preferred order, without duplicates; empty when the name does not
    /// resolve within `timeout`. An IP literal is returned as is, without a lookup.
    public static func resolve(_ host: String, timeout: TimeInterval = 2) async -> [String] {
        if isIPLiteral(host) { return [host] }
        let done = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ result: [String]) {
                let first = done.withLock { finished in
                    defer { finished = true }
                    return !finished
                }
                if first { continuation.resume(returning: result) }
            }
            // getaddrinfo blocks and cannot be cancelled; a late answer is simply dropped.
            DispatchQueue.global(qos: .utility).async { finish(lookup(host)) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish([]) }
        }
    }

    static func lookup(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM            // one entry per address instead of one per socket type
        hints.ai_flags = AI_ADDRCONFIG            // only families this Mac has an address for
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(head) }
        var out: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let addr = entry.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !out.contains(text) { out.append(text) }
        }
        return out
    }
}
