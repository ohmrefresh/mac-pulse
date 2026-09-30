import Darwin
import Foundation

/// One internet target the user probes: an IPv4 or IPv6 address, or a hostname, plus an optional label.
/// The first in the list is the Primary Target; the rest are Comparison Targets.
public struct ProbeTarget: Codable, Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable { case ipv4, ipv6, hostname }

    /// As the user typed it.
    public var address: String
    public var label: String?

    public init(_ address: String, label: String? = nil) {
        self.address = address
        self.label = label
    }

    public var isValid: Bool { Self.kind(of: address) != nil }

    /// Label if set, else the address.
    public var displayName: String { label ?? address }

    /// Nil when `address` is none of the three forms, or is a link-local IPv6 address without a
    /// "%interface" scope. Surrounding whitespace is ignored.
    public static func kind(of address: String) -> Kind? {
        let s = address.trimmingCharacters(in: .whitespaces)
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return .ipv4 }
        var v6 = in6_addr()
        if let percent = s.firstIndex(of: "%") {
            // Scoped IPv6 ("fe80::1%en0"): the only form in which a link-local address is reachable.
            let scope = s[s.index(after: percent)...]
            return !scope.isEmpty && inet_pton(AF_INET6, String(s[..<percent]), &v6) == 1 ? .ipv6 : nil
        }
        if inet_pton(AF_INET6, s, &v6) == 1 {
            // Link-local (fe80::/10) without a scope cannot be sent anywhere.
            let b = v6.__u6_addr.__u6_addr8
            return b.0 == 0xfe && b.1 & 0xc0 == 0x80 ? nil : .ipv6
        }
        return isHostname(s) ? .hostname : nil
    }

    /// RFC 1123: dot-separated labels of 1–63 letters, digits and inner hyphens, 253 characters in all.
    /// An all-numeric last label is rejected, so a mistyped IPv4 ("1.1.1") is not taken for a name.
    static func isHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 253 else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        let valid = labels.allSatisfy { label in
            label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        return valid && !(labels.last!.allSatisfy(\.isNumber))
    }
}

public enum ProbeTargets {
    /// Each target adds ~120 KB/h of probes; 4 keeps the app under its 1 MB/h network budget.
    public static let maxCount = 4
    public static let defaults = [ProbeTarget("1.1.1.1"), ProbeTarget("8.8.8.8")]

    /// The comparison target paired with a single ping host before targets were editable.
    public static func comparison(for primary: String) -> String {
        primary == "8.8.8.8" ? "1.1.1.1" : "8.8.8.8"
    }

    /// The list for a user who had only the single "Ping host" setting.
    public static func migrated(from pingTarget: String) -> [ProbeTarget] {
        let primary = pingTarget.trimmingCharacters(in: .whitespaces)
        guard ProbeTarget.kind(of: primary) != nil else { return defaults }
        return [ProbeTarget(primary), ProbeTarget(comparison(for: primary))]
    }

    /// A usable list: trimmed, invalid entries and duplicates (case-insensitive) dropped, blank labels
    /// removed, at most `maxCount`. Falls back to `defaults` rather than ever being empty.
    public static func sanitized(_ targets: [ProbeTarget]) -> [ProbeTarget] {
        var seen = Set<String>()
        var out: [ProbeTarget] = []
        for t in targets where out.count < maxCount {
            let address = t.address.trimmingCharacters(in: .whitespaces)
            guard ProbeTarget.kind(of: address) != nil, seen.insert(address.lowercased()).inserted else { continue }
            let label = t.label?.trimmingCharacters(in: .whitespaces)
            out.append(ProbeTarget(address, label: label?.isEmpty == false ? label : nil))
        }
        return out.isEmpty ? defaults : out
    }
}
