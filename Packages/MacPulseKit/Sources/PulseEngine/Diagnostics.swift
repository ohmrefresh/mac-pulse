import Foundation
import PulseCore

/// A cause is always hedged (PRD §10: never present a heuristic as a guaranteed cause).
/// There is deliberately no unhedged case.
public enum PossibleCause: Sendable, Equatable {
    case likely(String)
    case possibly(String)

    public var text: String {
        switch self {
        case .likely(let s): "Likely: \(s)"
        case .possibly(let s): "Possibly: \(s)"
        }
    }
}

public struct Finding: Sendable, Equatable, Identifiable {
    public enum Area: String, Sendable { case cpu, memory, network, thermal, disk }

    public var area: Area
    public var health: HealthLevel
    public var title: String
    /// Measured facts only — numbers, no interpretation.
    public var observed: [String]
    public var possibleCause: PossibleCause
    public var recommendation: String
    public var id: String { "\(area.rawValue)-\(title)" }
}

public struct DiagnosticReport: Sendable, Equatable {
    public var from: Date
    public var to: Date
    /// Empty means no problems detected in the window.
    public var findings: [Finding]
}

/// Facts gathered for one diagnostic run. Plain values so the rules are testable with fixtures.
public struct DiagnosticInput: Sendable, Equatable {
    public struct Probe: Sendable, Equatable {
        public var address: String
        public var avgMs: Double?
        public var lossPercent: Double
        public init(address: String, avgMs: Double?, lossPercent: Double) {
            self.address = address
            self.avgMs = avgMs
            self.lossPercent = lossPercent
        }
    }

    public var from: Date
    public var to: Date
    public var cpuPeak: Double?
    public var cpuAverage: Double?
    /// Average CPU % per process name over the window, highest first.
    public var topProcesses: [(name: String, cpu: Double)]
    public var memoryPressurePeak: HealthLevel?
    public var memoryUsedPercent: Double?
    public var swapGrowthBytes: Double?
    public var swapUsedBytes: Double?
    public var thermalPeak: ThermalState?
    public var diskFreeBytes: Double?
    public var connectivity: Connectivity?
    public var gateway: Probe?
    public var internet: [Probe]
    public var dns: (server: String, ms: Double?)?

    public init(from: Date, to: Date) {
        self.from = from
        self.to = to
        topProcesses = []
        internet = []
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.from == b.from && a.to == b.to && a.cpuPeak == b.cpuPeak && a.cpuAverage == b.cpuAverage
            && a.topProcesses.map(\.name) == b.topProcesses.map(\.name) && a.topProcesses.map(\.cpu) == b.topProcesses.map(\.cpu)
            && a.memoryPressurePeak == b.memoryPressurePeak && a.memoryUsedPercent == b.memoryUsedPercent
            && a.swapGrowthBytes == b.swapGrowthBytes && a.swapUsedBytes == b.swapUsedBytes
            && a.thermalPeak == b.thermalPeak && a.diskFreeBytes == b.diskFreeBytes && a.connectivity == b.connectivity
            && a.gateway == b.gateway && a.internet == b.internet && a.dns?.server == b.dns?.server && a.dns?.ms == b.dns?.ms
    }
}

public struct DiagnosticsConfig: Sendable {
    public var cpu = Threshold(warning: 80, critical: 95)
    public var network = NetworkThresholds()
    public var gatewayLatencyMs: Double = 100
    public var dnsSlowMs: Double = 200
    public var swapGrowthBytes: Double = 256 * 1_048_576
    public var lowDiskBytes: Double = 10e9
    public init() {}
}

/// Deterministic rule catalog (plan decision 8).
public enum DiagnosticRules {
    public static func evaluate(_ i: DiagnosticInput, config c: DiagnosticsConfig = DiagnosticsConfig()) -> DiagnosticReport {
        var f: [Finding] = []
        f += network(i, c)
        f += cpu(i, c)
        f += memory(i, c)
        f += thermal(i, c)
        f += disk(i, c)
        return DiagnosticReport(from: i.from, to: i.to, findings: f.sorted { $0.health > $1.health })
    }

    static func network(_ i: DiagnosticInput, _ c: DiagnosticsConfig) -> [Finding] {
        if i.connectivity == .offline {
            return [Finding(area: .network, health: .critical, title: "No network connection",
                            observed: ["No active network route"],
                            possibleCause: .likely("Wi-Fi or Ethernet is disconnected, or the network is unavailable"),
                            recommendation: "Check the Wi-Fi/Ethernet connection in System Settings › Network.")]
        }
        var out: [Finding] = []
        let bad: (DiagnosticInput.Probe) -> Bool = { p in
            p.avgMs == nil || p.lossPercent >= c.network.packetLossPercent.warning || (p.avgMs ?? 0) >= c.network.latencyMs.warning
        }
        let gatewayBad = i.gateway.map { $0.avgMs == nil || $0.lossPercent >= c.network.packetLossPercent.warning || ($0.avgMs ?? 0) >= c.gatewayLatencyMs } ?? false
        let badTargets = i.internet.filter(bad)
        let facts = ([i.gateway.map { describe("Gateway", $0) }] + i.internet.map { describe($0.address, $0) }).compactMap { $0 }

        if gatewayBad {
            out.append(Finding(area: .network, health: .critical, title: "Local network problem", observed: facts,
                               possibleCause: .likely("the Wi-Fi/LAN link to the router is weak or congested"),
                               recommendation: "Move closer to the router, try another band or a wired connection, or restart the router."))
        } else if !i.internet.isEmpty && badTargets.count == i.internet.count {
            out.append(Finding(area: .network, health: badTargets.contains { ($0.avgMs ?? .infinity) >= c.network.latencyMs.critical || $0.lossPercent >= c.network.packetLossPercent.critical } ? .critical : .warning,
                               title: "Internet connection degraded", observed: facts,
                               possibleCause: .likely("a problem upstream of your router (ISP or its network), since the gateway responds normally"),
                               recommendation: "Check your ISP's status page; if it persists, restart the modem or contact the ISP."))
        } else if let target = badTargets.first {
            out.append(Finding(area: .network, health: .warning, title: "One internet target is slow", observed: facts,
                               possibleCause: .possibly("an issue specific to \(target.address) or the route to it, since other targets respond normally"),
                               recommendation: "Usually no action needed. Change the ping host in Settings if it keeps happening."))
        }

        if let dns = i.dns {
            let internetOK = !i.internet.isEmpty && badTargets.isEmpty
            if let ms = dns.ms, ms >= c.dnsSlowMs {
                out.append(Finding(area: .network, health: .warning, title: "DNS is slow",
                                   observed: ["DNS \(dns.server): \(Int(ms.rounded())) ms"] + i.internet.compactMap { p in p.avgMs.map { "\(p.address): \(Int($0.rounded())) ms" } },
                                   possibleCause: internetOK ? .likely("the DNS resolver is responding slowly") : .possibly("general network slowness is also affecting DNS"),
                                   recommendation: "Try another DNS server (e.g. 1.1.1.1) in System Settings › Network › Details › DNS."))
            } else if dns.ms == nil {
                out.append(Finding(area: .network, health: .critical, title: "DNS not responding",
                                   observed: ["DNS \(dns.server): no answer within 2 s"],
                                   possibleCause: internetOK ? .likely("the DNS resolver is down or unreachable") : .possibly("the network outage is also blocking DNS"),
                                   recommendation: "Try another DNS server, or restart the router if it provides DNS."))
            }
        }
        return out
    }

    static func cpu(_ i: DiagnosticInput, _ c: DiagnosticsConfig) -> [Finding] {
        guard let peak = i.cpuPeak, peak >= c.cpu.warning else { return [] }
        var observed = ["Peak CPU: \(pct(peak))"]
        if let avg = i.cpuAverage { observed.append("Average CPU: \(pct(avg))") }
        let top = i.topProcesses.prefix(3)
        observed += top.map { "\($0.name): \(pct($0.cpu)) average" }
        let cause: PossibleCause = top.first.map { .likely("load from \($0.name)" + (top.count > 1 ? " and other busy processes" : "")) }
            ?? .possibly("a short burst of work that was not captured by process sampling")
        return [Finding(area: .cpu, health: c.cpu.health(for: peak), title: "High CPU usage", observed: observed,
                        possibleCause: cause,
                        recommendation: top.first.map { "Check whether \($0.name) is expected to be this busy; quit or pause it if not." }
                            ?? "Open the Processes view to see what is running.")]
    }

    static func memory(_ i: DiagnosticInput, _ c: DiagnosticsConfig) -> [Finding] {
        guard let peak = i.memoryPressurePeak, peak >= .warning else { return [] }
        var observed = ["Memory pressure reached \(peak == .critical ? "Critical" : "Warning")"]
        if let used = i.memoryUsedPercent { observed.append("Memory in use: \(pct(used))") }
        if let swap = i.swapUsedBytes { observed.append("Swap used: \(gb(swap))") }
        let swapGrew = (i.swapGrowthBytes ?? 0) >= c.swapGrowthBytes
        if swapGrew, let g = i.swapGrowthBytes { observed.append("Swap grew by \(gb(g))") }
        return [Finding(area: .memory, health: peak, title: "Memory pressure", observed: observed,
                        possibleCause: swapGrew ? .likely("running apps need more memory than is installed, so macOS is swapping")
                                                : .possibly("a temporary spike in memory demand"),
                        recommendation: "Quit memory-heavy apps you are not using (see Processes, sorted by Memory).")]
    }

    static func thermal(_ i: DiagnosticInput, _ c: DiagnosticsConfig) -> [Finding] {
        guard let t = i.thermalPeak, t.health >= .warning else { return [] }
        var observed = ["Thermal state reached \(t == .critical ? "Critical" : "Serious")"]
        if let peak = i.cpuPeak { observed.append("Peak CPU: \(pct(peak))") }
        let busy = (i.cpuPeak ?? 0) >= c.cpu.warning
        return [Finding(area: .thermal, health: t.health, title: "Mac is running hot", observed: observed,
                        possibleCause: busy ? .likely("sustained CPU load; macOS may be throttling performance")
                                            : .possibly("high ambient temperature or blocked ventilation"),
                        recommendation: busy ? "Reduce the load from the busiest processes and keep vents clear."
                                             : "Keep the Mac on a hard surface with clear vents, away from heat sources.")]
    }

    static func disk(_ i: DiagnosticInput, _ c: DiagnosticsConfig) -> [Finding] {
        guard let free = i.diskFreeBytes, free < c.lowDiskBytes else { return [] }
        return [Finding(area: .disk, health: free < c.lowDiskBytes / 2 ? .critical : .warning, title: "Low disk space",
                        observed: ["Free space: \(gb(free))"],
                        possibleCause: .likely("large files, caches or backups filling the startup disk"),
                        recommendation: "Use System Settings › General › Storage to find and remove large items.")]
    }

    private static func describe(_ label: String, _ p: DiagnosticInput.Probe) -> String {
        "\(label): " + (p.avgMs.map { "\(Int($0.rounded())) ms" } ?? "no reply") + ", loss \(pct(p.lossPercent))"
    }

    private static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    private static func gb(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }
}
