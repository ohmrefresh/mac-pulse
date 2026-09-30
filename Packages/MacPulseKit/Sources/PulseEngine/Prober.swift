import Foundation
import PulseCore
import PulseCollectors
import PulseStore

public struct ProbeReading: Sendable, Equatable {
    /// The IP address probed; for an unresolved hostname, the name as typed.
    public var address: String
    /// Nil when the latest probe timed out.
    public var latencyMs: Double?
    /// Over the last `LossWindow.capacity` probes.
    public var lossPercent: Double?
    /// The user's label for an internet target.
    public var label: String?
    /// The internet target as the user typed it (a hostname or an IP); nil for the gateway.
    public var host: String?
    /// The hostname did not resolve: a state of its own, not a timeout, and not counted as loss.
    public var unresolved: Bool

    public init(address: String, latencyMs: Double?, lossPercent: Double?, label: String? = nil,
                host: String? = nil, unresolved: Bool = false) {
        self.address = address
        self.latencyMs = latencyMs
        self.lossPercent = lossPercent
        self.label = label
        self.host = host
        self.unresolved = unresolved
    }

    /// Label, else the target as typed, else the address.
    public var displayName: String { label ?? host ?? address }
}

public struct DNSReading: Sendable, Equatable {
    public var server: String
    /// Nil when the resolver did not answer in time.
    public var latencyMs: Double?
}

public struct NetworkHealthReading: Sendable, Equatable {
    public var connectivity: Connectivity
    public var gateway: ProbeReading?
    /// The Primary Target (first in the user's list); drives network health.
    public var internet: ProbeReading?
    /// Comparison Targets, in list order: tell a target-specific problem from a general upstream one.
    public var comparisons: [ProbeReading]
    public var dns: DNSReading?
    public var health: HealthLevel

    public init(connectivity: Connectivity, gateway: ProbeReading?, internet: ProbeReading?,
                comparisons: [ProbeReading] = [], dns: DNSReading? = nil, health: HealthLevel) {
        self.connectivity = connectivity
        self.gateway = gateway
        self.internet = internet
        self.comparisons = comparisons
        self.dns = dns
        self.health = health
    }

    /// Pure: health from the Primary Target's latency/loss (PRD §7), Offline ⇒ Critical.
    /// A primary that does not resolve is Warning: something is wrong, but it is not an outage.
    static func make(connectivity: Connectivity, gateway: ProbeReading?, internet: ProbeReading?,
                     comparisons: [ProbeReading] = [], dns: DNSReading? = nil,
                     thresholds: NetworkThresholds) -> NetworkHealthReading {
        let health = connectivity == .online && internet?.unresolved == true
            ? .warning
            : thresholds.health(connectivity: connectivity, latencyMs: internet?.latencyMs, packetLossPercent: internet?.lossPercent)
        return NetworkHealthReading(connectivity: connectivity, gateway: gateway, internet: internet,
                                    comparisons: comparisons, dns: dns, health: health)
    }
}

/// Active network probes on their own loop, so a timeout never delays the 1 s collectors.
actor Prober {
    typealias Ping = @Sendable (_ address: String, _ sequence: UInt16) async -> ICMPPing.Outcome
    typealias Resolve = @Sendable (_ host: String) async -> [String]

    /// Hostnames are re-resolved this often, and whenever the gateway changes; never per probe.
    static let resolveInterval: TimeInterval = 300

    private let interval: TimeInterval
    private var targets: [ProbeTarget]
    private var thresholds: NetworkThresholds
    private var sequence: UInt16 = 0
    private var gatewayAddress: String?
    private var gatewayLoss = LossWindow()
    /// Keyed by the target as typed, so a reorder keeps each target's history.
    private var losses: [String: LossWindow] = [:]
    private var resolved: [String: (addresses: [String], at: TimeInterval)] = [:]
    private let ping: Ping
    private let resolve: Resolve
    private var loop: Task<Void, Never>?
    private let recorder: HistoryRecorder?

    init(interval: TimeInterval = 5, targets: [ProbeTarget] = ProbeTargets.defaults,
         thresholds: NetworkThresholds = NetworkThresholds(), recorder: HistoryRecorder? = nil,
         ping: @escaping Ping = { await ICMPPing.probe($0, timeout: 1, sequence: $1) },
         resolve: @escaping Resolve = { await HostResolver.resolve($0) }) {
        self.interval = interval
        self.recorder = recorder
        self.targets = targets
        self.thresholds = thresholds
        self.ping = ping
        self.resolve = resolve
    }

    func start(publish: @escaping @Sendable @MainActor (NetworkHealthReading) -> Void) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let reading = await self.probe()
                await self.recorder?.record(HistorySamples.from(reading, at: Date()))
                await publish(reading)
                let interval = self.interval
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.1))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Targets still in the list keep their loss history; removed ones lose it.
    func configure(targets: [ProbeTarget], thresholds: NetworkThresholds) {
        let keep = Set(targets.map(\.address))
        losses = losses.filter { keep.contains($0.key) }
        resolved = resolved.filter { keep.contains($0.key) }
        self.targets = targets
        self.thresholds = thresholds
    }

    /// A new network can resolve names differently (split DNS, VPN): forget cached addresses.
    func networkChanged() {
        resolved = [:]
    }

    /// Sequence numbers for one round: one per target, then the gateway. `next` is the following
    /// round's base, so no two probes in flight share a sequence.
    static func sequences(base: UInt16, targetCount: Int) -> (targets: [UInt16], gateway: UInt16, next: UInt16) {
        ((0..<targetCount).map { base &+ UInt16($0) }, base &+ UInt16(targetCount), base &+ UInt16(targetCount + 1))
    }

    private func probe() async -> NetworkHealthReading {
        guard NetworkCollector.primaryInterface() != nil else {
            return .make(connectivity: .offline, gateway: nil, internet: nil, thresholds: thresholds)
        }
        let gateway = NetworkCollector.gatewayAddress()
        if gateway != gatewayAddress {
            gatewayAddress = gateway
            gatewayLoss = LossWindow()   // new network: old history no longer applies
            networkChanged()
        }
        let gatewaySequence = Self.sequences(base: sequence, targetCount: targets.count).gateway
        let resolver = DNSProbe.systemResolver()
        let ping = self.ping
        async let internetReadings = probeInternet(now: ProcessInfo.processInfo.systemUptime)
        async let gatewayRTT: Double? = gateway == nil ? nil : ping(gateway!, gatewaySequence).milliseconds
        async let dnsRTT: Double? = resolver == nil ? nil : DNSProbe.query(server: resolver!)
        let (readings, gatewayResult, dnsResult) = await (internetReadings, gatewayRTT, dnsRTT)

        var gatewayReading: ProbeReading?
        if let gateway {
            gatewayLoss.record(success: gatewayResult != nil)
            gatewayReading = ProbeReading(address: gateway, latencyMs: gatewayResult, lossPercent: gatewayLoss.lossPercent)
        }
        let dns = resolver.map { DNSReading(server: $0, latencyMs: dnsResult) }
        return .make(connectivity: .online, gateway: gatewayReading, internet: readings.first,
                     comparisons: Array(readings.dropFirst()), dns: dns, thresholds: thresholds)
    }

    /// One reading per target, in list order, probed in parallel. Advances the sequence base.
    func probeInternet(now: TimeInterval) async -> [ProbeReading] {
        let targets = self.targets
        let round = Self.sequences(base: sequence, targetCount: targets.count)
        sequence = round.next
        let candidates = await addresses(for: targets.map(\.address), now: now)

        let ping = self.ping
        let outcomes = await withTaskGroup(of: (Int, String?, Double?).self) { group in
            for (i, addresses) in candidates.enumerated() {
                group.addTask {
                    // First usable address; an IPv6 one that cannot be sent (no route) falls back to IPv4.
                    for address in Self.attemptOrder(addresses) {
                        let outcome = await ping(address, round.targets[i])
                        if outcome != .sendFailed { return (i, address, outcome.milliseconds) }
                    }
                    return (i, addresses.first, nil)
                }
            }
            var out = [(address: String?, ms: Double?)](repeating: (nil, nil), count: candidates.count)
            for await (i, address, ms) in group { out[i] = (address, ms) }
            return out
        }

        return targets.enumerated().map { i, target in
            guard let first = candidates[i].first else {
                return ProbeReading(address: target.address, latencyMs: nil, lossPercent: nil,
                                    label: target.label, host: target.address, unresolved: true)
            }
            losses[target.address, default: LossWindow()].record(success: outcomes[i].ms != nil)
            return ProbeReading(address: outcomes[i].address ?? first, latencyMs: outcomes[i].ms,
                                lossPercent: losses[target.address]?.lossPercent, label: target.label, host: target.address)
        }
    }

    /// The first address, then the first IPv4 one if the first is IPv6.
    static func attemptOrder(_ addresses: [String]) -> [String] {
        guard let first = addresses.first else { return [] }
        guard ICMPPing.Family(address: first) == .ipv6,
              let v4 = addresses.first(where: { ICMPPing.Family(address: $0) == .ipv4 }) else { return [first] }
        return [first, v4]
    }

    /// Cached addresses per host; stale or missing ones are looked up in parallel, so N names that
    /// fail cost one resolver timeout, not N.
    private func addresses(for hosts: [String], now: TimeInterval) async -> [[String]] {
        let stale = Set(hosts.filter { host in resolved[host].map { now - $0.at >= Self.resolveInterval } ?? true })
        let resolve = self.resolve
        let fresh = await withTaskGroup(of: (String, [String]).self) { group in
            for host in stale { group.addTask { (host, await resolve(host)) } }
            var out: [String: [String]] = [:]
            for await (host, addresses) in group { out[host] = addresses }
            return out
        }
        for (host, addresses) in fresh { resolved[host] = (addresses, now) }
        return hosts.map { resolved[$0]?.addresses ?? [] }
    }
}
