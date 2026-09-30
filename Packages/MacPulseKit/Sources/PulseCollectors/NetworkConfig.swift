import Darwin
import Foundation
import SystemConfiguration

public struct ProxySetting: Sendable, Equatable {
    public enum Kind: String, Sendable { case http = "HTTP", https = "HTTPS", socks = "SOCKS", autoConfig = "Auto-config (PAC)" }
    public var kind: Kind
    /// "host:port", or the PAC URL.
    public var target: String
}

public struct NetworkConfigReading: Sendable, Equatable {
    public var primaryInterface: String?
    /// Tunnel interfaces carrying routable IPv4 (VPN), e.g. ["utun4"].
    public var vpnInterfaces: [String]
    public var proxies: [ProxySetting]
    public var vpnActive: Bool { !vpnInterfaces.isEmpty }

    public init(primaryInterface: String?, vpnInterfaces: [String], proxies: [ProxySetting]) {
        self.primaryInterface = primaryInterface
        self.vpnInterfaces = vpnInterfaces
        self.proxies = proxies
    }
}

public enum NetworkConfigCollector {
    public static func sample() -> NetworkConfigReading {
        let primary = NetworkCollector.primaryInterface()
        let proxies = (SCDynamicStoreCopyProxies(nil) as? [String: Any]).map(parseProxies) ?? []
        return NetworkConfigReading(primaryInterface: primary,
                                    vpnInterfaces: vpnInterfaces(primary: primary, ipv4ByInterface: ipv4Addresses()),
                                    proxies: proxies)
    }

    /// Tunnels count as VPN when they are the primary route or hold a routable IPv4 address (split-tunnel
    /// VPNs). System tunnels (iCloud Private Relay, Continuity) carry only IPv6 link-local and are ignored.
    static func vpnInterfaces(primary: String?, ipv4ByInterface: [String: [String]]) -> [String] {
        let tunnels = ["utun", "ipsec", "ppp"]
        var result = Set<String>()
        if let primary, tunnels.contains(where: primary.hasPrefix) { result.insert(primary) }
        for (name, addresses) in ipv4ByInterface where tunnels.contains(where: name.hasPrefix) {
            if addresses.contains(where: { !$0.hasPrefix("169.254.") && !$0.hasPrefix("127.") }) { result.insert(name) }
        }
        return result.sorted()
    }

    static func parseProxies(_ d: [String: Any]) -> [ProxySetting] {
        func enabled(_ key: String) -> Bool { (d[key] as? Int ?? 0) != 0 }
        func hostPort(_ host: String, _ port: String) -> String? {
            guard let h = d[host] as? String, !h.isEmpty else { return nil }
            return (d[port] as? Int).map { "\(h):\($0)" } ?? h
        }
        var result: [ProxySetting] = []
        if enabled("HTTPEnable"), let t = hostPort("HTTPProxy", "HTTPPort") { result.append(.init(kind: .http, target: t)) }
        if enabled("HTTPSEnable"), let t = hostPort("HTTPSProxy", "HTTPSPort") { result.append(.init(kind: .https, target: t)) }
        if enabled("SOCKSEnable"), let t = hostPort("SOCKSProxy", "SOCKSPort") { result.append(.init(kind: .socks, target: t)) }
        if enabled("ProxyAutoConfigEnable"), let url = d["ProxyAutoConfigURLString"] as? String {
            result.append(.init(kind: .autoConfig, target: url))
        }
        return result
    }

    /// The address to show for an interface: its first one that is not link-local (self-assigned).
    public static func localIPv4(_ addresses: [String]) -> String? {
        addresses.first { !$0.hasPrefix("169.254.") }
    }

    /// IPv4 addresses by interface name, e.g. ["en0": ["192.168.1.42"]].
    public static func ipv4Addresses() -> [String: [String]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: [String]] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            result[name, default: []].append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return result
    }
}

/// Opt-in public IP lookup (decision D1): asks Cloudflare's trace endpoint on 1.1.1.1 — a host
/// the app already pings — only when the network changes and at most every 30 minutes.
public enum PublicIPLookup {
    public struct Result: Sendable, Equatable {
        public var ip: String
        /// ISO country code reported by Cloudflare, if present.
        public var country: String?
    }

    public static let endpoint = URL(string: "https://1.1.1.1/cdn-cgi/trace")!

    public static func fetch(session: URLSession = .shared) async -> Result? {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses Cloudflare trace "key=value" lines.
    static func parse(_ text: String) -> Result? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard let ip = fields["ip"], !ip.isEmpty else { return nil }
        return Result(ip: ip, country: fields["loc"])
    }
}
