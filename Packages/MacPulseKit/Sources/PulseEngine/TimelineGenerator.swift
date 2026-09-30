import Foundation
import PulseCore
import PulseCollectors

/// Tunable heuristics for timeline events (plan decision 9). Tuned during M1 dogfooding.
public struct TimelineConfig: Sendable, Equatable {
    /// A new Health Level must hold this long before it is logged.
    public var healthHold: TimeInterval = 10
    /// PRD §9 example "CPU > 80%".
    public var cpu = Threshold(warning: 80, critical: 95)
    public var processTopN = 3
    public var processCPUPercent: Double = 25
    public var processHold: TimeInterval = 10
    public var memoryGrowthBytes: UInt64 = 2 << 30
    public var memoryGrowthWindow: TimeInterval = 300
    /// Processes below this footprint are not tracked for growth, bounding the bookkeeping.
    public var memoryTrackFloor: UInt64 = 256 << 20

    public init() {}
}

/// Turns readings into debounced timeline events. Pure: no clock, no I/O.
public struct TimelineGenerator: Sendable {
    public var config: TimelineConfig

    struct Debounced {
        var reported: HealthLevel
        var candidate: HealthLevel
        var since: Date
    }

    private var health: [TimelineCategory: Debounced] = [:]
    private var thermal: ThermalState?
    private var onACPower: Bool?
    private var connectivity: Connectivity?
    private var interface: String?
    private var vpnInterfaces: [String]?
    private var targets: [ProbeTarget]?
    /// pid → when it first qualified as a CPU hog, and whether it has been announced.
    private var hogs: [Int32: (since: Date, announced: Bool, name: String)] = [:]
    /// pid → recent (time, bytes) samples inside the growth window.
    private var memory: [Int32: [(time: Date, bytes: UInt64)]] = [:]
    private var memoryAnnounced: [Int32: Date] = [:]

    public init(config: TimelineConfig = TimelineConfig()) {
        self.config = config
    }

    /// The debounced Health Level last reported for a category (what the timeline shows), nil before the first reading.
    public func reportedHealth(_ category: TimelineCategory) -> HealthLevel? {
        health[category]?.reported
    }

    // MARK: Snapshot readings

    public mutating func observe(_ s: Snapshot, at now: Date) -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        if let cpu = s.cpu {
            let level = config.cpu.health(for: cpu.totalPercent)
            events += debounce(.cpu, level, at: now, title: "CPU", detail: "\(Int(cpu.totalPercent.rounded()))%")
        }
        if let pressure = s.memory?.pressure {
            events += debounce(.memory, pressure.health, at: now, title: "Memory pressure",
                               detail: s.memory.map { "\(Int($0.usedPercent.rounded()))% used" })
        }
        if let t = s.thermal {
            if let old = thermal, old != t {
                events.append(TimelineEvent(time: now, category: .thermal, severity: t.health,
                                            title: "Thermal \(Self.name(old)) → \(Self.name(t))"))
            }
            thermal = t
        }
        if let b = s.battery {
            if let old = onACPower, old != b.onACPower {
                events.append(TimelineEvent(time: now, category: .battery, severity: .healthy,
                                            title: b.onACPower ? TimelineEpisodes.connectedToPowerTitle : TimelineEpisodes.switchedToBatteryTitle,
                                            detail: "\(Int(b.percent.rounded()))%"))
            }
            onACPower = b.onACPower
        }
        if let rows = s.processes {
            events += observeProcesses(rows, at: now)
        }
        return events
    }

    // MARK: Network readings

    public mutating func observe(_ r: NetworkHealthReading, interface newInterface: String?, at now: Date) -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        if let old = connectivity, old != r.connectivity {
            events.append(r.connectivity == .offline
                ? TimelineEvent(time: now, category: .connectivity, severity: .critical, title: "Offline",
                                detail: "No network route")
                : TimelineEvent(time: now, category: .connectivity, severity: .healthy, title: TimelineEpisodes.backOnlineTitle,
                                detail: newInterface.map { "via \($0)" }))
        }
        connectivity = r.connectivity

        if r.connectivity == .online, let newInterface {
            // Moves to/from a tunnel are reported as VPN events by observe(config:) instead.
            if let old = interface, old != newInterface, !Self.isVPN(old), !Self.isVPN(newInterface) {
                events.append(TimelineEvent(time: now, category: .connectivity, severity: .healthy,
                                            title: "Network changed", detail: "\(old) → \(newInterface)"))
            }
            interface = newInterface
            let detail = r.internet?.unresolved == true
                ? "can't resolve \(r.internet!.host ?? r.internet!.address)"
                : [r.internet?.latencyMs.map { "latency \(Int($0.rounded())) ms" } ?? "probe timeout",
                   r.internet?.lossPercent.map { "loss \(Int($0.rounded()))%" }].compactMap { $0 }.joined(separator: ", ")
            events += debounce(.network, r.health, at: now, title: "Network", detail: detail)
        }
        return events
    }

    /// An edit to the internet target list. Stored latency lines mean "slot 1 / slot 2 of the list",
    /// so this marks where they changed meaning. The first list seen is the baseline.
    public mutating func observe(targets new: [ProbeTarget], at now: Date) -> [TimelineEvent] {
        defer { targets = new }
        guard let old = targets, old != new else { return [] }
        return [TimelineEvent(time: now, category: .network, severity: .healthy, title: "Internet targets changed",
                              detail: new.map(\.displayName).joined(separator: ", "))]
    }

    /// VPN up/down from interface configuration, which also catches split-tunnel VPNs that never
    /// become the primary route.
    public mutating func observe(config: NetworkConfigReading, at now: Date) -> [TimelineEvent] {
        defer { vpnInterfaces = config.vpnInterfaces }
        guard let old = vpnInterfaces else { return [] }          // baseline
        if old.isEmpty && !config.vpnInterfaces.isEmpty {
            return [TimelineEvent(time: now, category: .connectivity, severity: .healthy, title: "VPN connected",
                                  detail: config.vpnInterfaces.joined(separator: ", "))]
        }
        if !old.isEmpty && config.vpnInterfaces.isEmpty {
            return [TimelineEvent(time: now, category: .connectivity, severity: .healthy, title: "VPN disconnected",
                                  detail: old.joined(separator: ", "))]
        }
        return []
    }

    // MARK: Helpers

    /// Logs a Health Level only once it has held for `healthHold`. The first observation sets the
    /// baseline silently so launch does not produce "→ Healthy" noise.
    private mutating func debounce(_ category: TimelineCategory, _ level: HealthLevel, at now: Date,
                                   title: String, detail: String?) -> [TimelineEvent] {
        guard level != .unknown else { return [] }
        guard var d = health[category] else {
            health[category] = Debounced(reported: level, candidate: level, since: now)
            return []
        }
        defer { health[category] = d }
        if level == d.reported {
            d.candidate = level
            return []
        }
        if level != d.candidate {
            d.candidate = level
            d.since = now
        }
        guard now.timeIntervalSince(d.since) >= config.healthHold else { return [] }
        let recovered = level == .healthy
        d.reported = level
        return [TimelineEvent(time: now, category: category, severity: level,
                              title: recovered ? "\(title)\(TimelineEpisodes.recoveredSuffix)" : "\(title) → \(Self.name(level))",
                              detail: detail)]
    }

    private mutating func observeProcesses(_ rows: [ProcessRow], at now: Date) -> [TimelineEvent] {
        var events: [TimelineEvent] = []

        // Tracking follows *hotness*, announcing follows rank. Keyed on rank, a process that
        // stayed busy while others spiked around it dropped out of the top N, lost its entry, and
        // was announced again on the way back — one busy app filling the timeline with one line.
        // An entry is forgotten only when the process cools below the bar, so the next
        // announcement needs a real recovery first.
        let hot = rows.filter { $0.cpuPercent > config.processCPUPercent }
        let hotPIDs = Set(hot.map(\.pid))
        hogs = hogs.filter { hotPIDs.contains($0.key) }            // cooled off: may be announced again later
        let top = hot.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(config.processTopN)
        for row in top {
            var hog = hogs[row.pid] ?? (since: now, announced: false, name: row.name)
            if !hog.announced, now.timeIntervalSince(hog.since) >= config.processHold {
                hog.announced = true
                events.append(TimelineEvent(time: now, category: .process, severity: .warning,
                                            title: "\(row.name) CPU increased",
                                            detail: "\(Int(row.cpuPercent.rounded()))% for \(Int(config.processHold)) s+"))
            }
            hogs[row.pid] = hog
        }

        let alive = Set(rows.map(\.pid))
        memory = memory.filter { alive.contains($0.key) }
        memoryAnnounced = memoryAnnounced.filter { alive.contains($0.key) && now.timeIntervalSince($0.value) < config.memoryGrowthWindow }
        for row in rows where row.memoryBytes >= config.memoryTrackFloor {
            var samples = (memory[row.pid] ?? []).filter { now.timeIntervalSince($0.time) <= config.memoryGrowthWindow }
            samples.append((now, row.memoryBytes))
            memory[row.pid] = samples
            let low = samples.map(\.bytes).min() ?? row.memoryBytes
            if row.memoryBytes >= low &+ config.memoryGrowthBytes, memoryAnnounced[row.pid] == nil {
                memoryAnnounced[row.pid] = now
                let grown = Double(row.memoryBytes - low) / Double(1 << 30)
                events.append(TimelineEvent(time: now, category: .process, severity: .warning,
                                            title: "\(row.name) memory grew",
                                            detail: String(format: "+%.1f GB in under %d min", grown, Int(config.memoryGrowthWindow / 60))))
            }
        }
        return events
    }

    static func isVPN(_ interface: String) -> Bool {
        ["utun", "ipsec", "ppp"].contains { interface.hasPrefix($0) }
    }

    static func name(_ level: HealthLevel) -> String {
        switch level {
        case .healthy: "Healthy"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }

    static func name(_ state: ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }
}
