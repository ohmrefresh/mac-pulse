import Foundation
import PulseCore
import PulseCollectors
import PulseStore

/// Gathers facts for a diagnostic run: the last 15 minutes of history plus a fresh probe burst.
enum DiagnosticsRunner {
    static let window: TimeInterval = 900
    static let burstCount = 10

    struct Live: Sendable {
        var memoryUsedPercent: Double?
        var diskFreeBytes: Double?
        /// The user's internet targets, Primary first.
        var targets: [ProbeTarget]
        var cpuFallback: [Double]      // used only when history is unavailable
    }

    static func run(history: HistoryStore?, live: Live, config: DiagnosticsConfig = DiagnosticsConfig(),
                    now: Date = Date()) async -> DiagnosticReport {
        var input = DiagnosticInput(from: now.addingTimeInterval(-window), to: now)
        input.memoryUsedPercent = live.memoryUsedPercent
        input.diskFreeBytes = live.diskFreeBytes

        if let history {
            let from = input.from
            let facts = try? await Task.detached { () -> HistoryFacts in
                try HistoryFacts.load(history, from: from, to: now)
            }.value
            facts?.apply(to: &input)
        } else if !live.cpuFallback.isEmpty {
            input.cpuPeak = live.cpuFallback.max()
            input.cpuAverage = live.cpuFallback.reduce(0, +) / Double(live.cpuFallback.count)
        }

        guard NetworkCollector.primaryInterface() != nil else {
            input.connectivity = .offline
            return DiagnosticRules.evaluate(input, config: config)
        }
        input.connectivity = .online
        let gateway = NetworkCollector.gatewayAddress()
        let resolver = DNSProbe.systemResolver()
        async let g: DiagnosticInput.Probe? = gateway == nil ? nil : burst(gateway!, base: 1_000)
        async let i = internetBursts(live.targets, resolve: { await HostResolver.resolve($0) }, burst: { await burst($0, base: $1) })
        async let d: Double? = resolver == nil ? nil : DNSProbe.query(server: resolver!)
        let (gw, internet, dnsMs) = await (g, i, d)
        input.gateway = gw
        input.internet = internet
        input.dns = resolver.map { ($0, dnsMs) }
        return DiagnosticRules.evaluate(input, config: config)
    }

    /// One burst per target, in parallel and in list order, each on its own sequence range. Probes are
    /// named as the user knows the target. A target that does not resolve is left out: it has nothing to
    /// ping, and reporting it as 100 % loss would blame the network.
    static func internetBursts(_ targets: [ProbeTarget],
                               resolve: @escaping @Sendable (String) async -> [String],
                               burst: @escaping @Sendable (String, UInt16) async -> DiagnosticInput.Probe) async -> [DiagnosticInput.Probe] {
        await withTaskGroup(of: (Int, DiagnosticInput.Probe?).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    // A dual-stack name bursts over IPv4: a burst cannot fall back mid-way if IPv6 has no route.
                    guard let address = Prober.attemptOrder(await resolve(target.address)).last else { return (index, nil) }
                    var probe = await burst(address, 2_000 &+ UInt16(index) &* 1_000)
                    probe.address = target.displayName
                    return (index, probe)
                }
            }
            var out = [DiagnosticInput.Probe?](repeating: nil, count: targets.count)
            for await (index, probe) in group { out[index] = probe }
            return out.compactMap { $0 }
        }
    }

    /// `burstCount` pings 100 ms apart: average of replies, loss over all.
    static func burst(_ address: String, base: UInt16) async -> DiagnosticInput.Probe {
        var replies: [Double] = []
        for n in 0..<burstCount {
            if let ms = await ICMPPing.ping(address, timeout: 1, sequence: base &+ UInt16(n)) { replies.append(ms) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let loss = Double(burstCount - replies.count) / Double(burstCount) * 100
        return .init(address: address, avgMs: replies.isEmpty ? nil : replies.reduce(0, +) / Double(replies.count), lossPercent: loss)
    }
}

/// History-derived facts. Pure aggregation helpers are separated for tests.
struct HistoryFacts: Sendable {
    var cpu: [HistoryPoint] = []
    var pressure: [HistoryPoint] = []
    var swap: [HistoryPoint] = []
    var thermal: [HistoryPoint] = []
    var cpuTemperature: [HistoryPoint] = []
    var processes: [ProcessSample] = []

    static func load(_ store: HistoryStore, from: Date, to: Date) throws -> HistoryFacts {
        HistoryFacts(cpu: try store.series(.cpuPercent, from: from, to: to, now: to),
                     pressure: try store.series(.memoryPressure, from: from, to: to, now: to),
                     swap: try store.series(.swapUsedBytes, from: from, to: to, now: to),
                     thermal: try store.series(.thermalState, from: from, to: to, now: to),
                     cpuTemperature: try store.series(.cpuTemperatureC, from: from, to: to, now: to),
                     processes: try store.processSamples(from: from, to: to))
    }

    func apply(to i: inout DiagnosticInput) {
        if !cpu.isEmpty {
            i.cpuPeak = cpu.map(\.max).max()
            i.cpuAverage = cpu.map(\.avg).reduce(0, +) / Double(cpu.count)
        }
        i.memoryPressurePeak = pressure.map(\.max).max().flatMap { HealthLevel(rawValue: Int($0)) }
        if let first = swap.first, let last = swap.last {
            i.swapUsedBytes = last.avg
            i.swapGrowthBytes = last.avg - first.avg
        }
        i.thermalPeak = thermal.map(\.max).max().flatMap { ThermalState(rawValue: Int($0)) }
        i.cpuTemperaturePeak = cpuTemperature.map(\.max).max()
        i.topProcesses = Self.averageCPU(processes)
    }

    /// Mean CPU per process name across all scans in the window (a scan where a process is absent
    /// counts as 0), highest first, ignoring ones under 1%. Same-name processes are summed per scan.
    static func averageCPU(_ samples: [ProcessSample]) -> [(name: String, cpu: Double)] {
        let scans = Set(samples.map(\.time)).count
        guard scans > 0 else { return [] }
        var totals: [String: Double] = [:]
        for s in samples { totals[s.name, default: 0] += s.cpuPercent }
        return totals.map { (name: $0.key, cpu: $0.value / Double(scans)) }
            .filter { $0.cpu >= 1 }
            .sorted { $0.cpu > $1.cpu }
    }
}
