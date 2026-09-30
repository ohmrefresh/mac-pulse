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
    /// What the primary interface is, e.g. "Wi‑Fi" or "Ethernet". Nil for interfaces that are not
    /// network hardware (VPN tunnels) or when SystemConfiguration does not know it.
    public var interfaceKind: String?
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double
    /// First routable IPv4 address of the primary interface, e.g. "192.168.1.42".
    public var localIPv4: String?

    public init(interface: String?, interfaceKind: String? = nil, downBytesPerSec: Double, upBytesPerSec: Double,
                localIPv4: String? = nil) {
        self.interface = interface
        self.interfaceKind = interfaceKind
        self.localIPv4 = localIPv4
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
    private var primary: (name: String?, kind: String?, ipv4: String?, resolvedAt: TimeInterval)?
    /// The primary interface rarely changes and each lookup opens a SystemConfiguration session.
    private static let primaryRefreshInterval: TimeInterval = 5

    public init() {}

    /// First call after start or an interface change primes the baseline and reports zero rates.
    public mutating func sample(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NetworkReading {
        if primary == nil || now - primary!.resolvedAt >= Self.primaryRefreshInterval {
            let name = Self.primaryInterface()
            // The kind lookup enumerates every interface, so it runs only when the primary changes.
            let kind = primary != nil && name == primary?.name ? primary?.kind : name.flatMap(Self.interfaceKind)
            // The address is re-read on every refresh: a DHCP renewal can change it on the same interface.
            let ipv4 = name.flatMap { NetworkConfigCollector.localIPv4(NetworkConfigCollector.ipv4Addresses()[$0] ?? []) }
            primary = (name, kind, ipv4, now)
        }
        guard let name = primary?.name, let counters = Self.counters(only: name)[name] else {
            previous = nil
            return NetworkReading(interface: nil, downBytesPerSec: 0, upBytesPerSec: 0)
        }
        defer { previous = (counters, now) }
        var reading = previous.flatMap {
            NetworkRate.reading(from: $0.counters, at: $0.time, to: counters, at: now)
        } ?? NetworkReading(interface: name, downBytesPerSec: 0, upBytesPerSec: 0)
        reading.interfaceKind = primary?.kind
        reading.localIPv4 = primary?.ipv4
        return reading
    }

    /// `interfaceKind` of a Wi‑Fi link. Spelled with a non-breaking hyphen (U+2011); compare against this.
    public static let wifiKind = "Wi‑Fi"

    /// "Wi‑Fi", or the system's own name for other hardware ("Ethernet", "Thunderbolt Bridge").
    /// Needs no Location Services permission: it names the kind of link, never the network.
    public static func interfaceKind(_ bsdName: String) -> String? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
              let match = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }) else { return nil }
        if SCNetworkInterfaceGetInterfaceType(match) == kSCNetworkInterfaceTypeIEEE80211 { return wifiKind }
        return SCNetworkInterfaceGetLocalizedDisplayName(match) as String?
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
