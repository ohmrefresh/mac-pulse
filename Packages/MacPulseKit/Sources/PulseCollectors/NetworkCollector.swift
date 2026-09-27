import Darwin
import Foundation
import SystemConfiguration

public struct InterfaceCounters: Sendable, Equatable {
    public var name: String
    public var receivedBytes: UInt64
    public var sentBytes: UInt64

    public init(name: String, receivedBytes: UInt64, sentBytes: UInt64) {
        self.name = name
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public struct NetworkReading: Sendable, Equatable {
    /// BSD name of the primary interface (e.g. "en0"), nil when there is no route.
    public var interface: String?
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double

    public init(interface: String?, downBytesPerSec: Double, upBytesPerSec: Double) {
        self.interface = interface
        self.downBytesPerSec = downBytesPerSec
        self.upBytesPerSec = upBytesPerSec
    }
}

public enum NetworkRate {
    /// Rate between two snapshots of the same interface. Nil if the interface changed,
    /// counters went backwards (interface reset), or no time elapsed.
    public static func reading(from previous: InterfaceCounters, at previousTime: TimeInterval,
                               to current: InterfaceCounters, at currentTime: TimeInterval) -> NetworkReading? {
        let elapsed = currentTime - previousTime
        guard elapsed > 0, previous.name == current.name,
              current.receivedBytes >= previous.receivedBytes,
              current.sentBytes >= previous.sentBytes else { return nil }
        return NetworkReading(
            interface: current.name,
            downBytesPerSec: Double(current.receivedBytes - previous.receivedBytes) / elapsed,
            upBytesPerSec: Double(current.sentBytes - previous.sentBytes) / elapsed
        )
    }
}

/// Throughput of the primary interface only. Summing all interfaces double-counts VPN
/// tunnels (utun*) on top of the physical link carrying them.
public struct NetworkCollector: Sendable {
    private var previous: (counters: InterfaceCounters, time: TimeInterval)?
    private var primary: (name: String?, resolvedAt: TimeInterval)?
    /// The primary interface rarely changes and each lookup opens a SystemConfiguration session.
    private static let primaryRefreshInterval: TimeInterval = 5

    public init() {}

    /// First call after start or an interface change primes the baseline and reports zero rates.
    public mutating func sample(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NetworkReading {
        if primary == nil || now - primary!.resolvedAt >= Self.primaryRefreshInterval {
            primary = (Self.primaryInterface(), now)
        }
        guard let name = primary?.name, let counters = Self.counters(only: name)[name] else {
            previous = nil
            return NetworkReading(interface: nil, downBytesPerSec: 0, upBytesPerSec: 0)
        }
        defer { previous = (counters, now) }
        if let previous, let reading = NetworkRate.reading(from: previous.counters, at: previous.time, to: counters, at: now) {
            return reading
        }
        return NetworkReading(interface: name, downBytesPerSec: 0, upBytesPerSec: 0)
    }

    public static func primaryInterface() -> String? {
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let name = globalState(key)?["PrimaryInterface"] as? String { return name }
        }
        return nil
    }

    /// IPv4 default router of the primary service, e.g. "192.168.1.1".
    public static func gatewayAddress() -> String? {
        globalState("State:/Network/Global/IPv4")?["Router"] as? String
    }

    private static func globalState(_ key: String) -> [String: Any]? {
        let store = SCDynamicStoreCreate(nil, "MacPulse" as CFString, nil, nil)
        return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    /// 64-bit per-interface byte counters via NET_RT_IFLIST2 (getifaddrs only exposes 32-bit ones, which wrap at 4 GB).
    /// - Parameter only: restrict to one interface; others are skipped without a name lookup.
    public static func counters(only name: String? = nil) -> [String: InterfaceCounters] {
        let wantedIndex = name.map { if_nametoindex($0) }
        if wantedIndex == 0 { return [:] }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: InterfaceCounters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, wantedIndex == nil || UInt32(header.ifm_index) == wantedIndex! {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil {
                        let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        result[name] = InterfaceCounters(name: name,
                                                         receivedBytes: message.ifm_data.ifi_ibytes,
                                                         sentBytes: message.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }
}
