import Foundation
import Observation
import PulseCore
import PulseCollectors
import PulseStore

/// Latest readings for the UI. Only fields present in a snapshot are replaced, so views
/// observing slow metrics are not invalidated by fast ticks.
@MainActor
@Observable
public final class LiveMetrics {
    public private(set) var cpu: CPUReading?
    public private(set) var memory: MemoryReading?
    public private(set) var network: NetworkReading?
    public private(set) var disk: DiskReading?
    /// Nil on Macs without a battery, or before the first power sample.
    public private(set) var battery: BatteryReading?
    public private(set) var thermal: ThermalState?
    public private(set) var processes: [ProcessRow] = []
    public private(set) var networkHealth: NetworkHealthReading?
    public let processorName: String?

    public private(set) var samplingInterval: TimeInterval

    /// Up to 300 samples (5 min at 1 s): sparklines use the tail, cards show averages.
    public private(set) var cpuHistory = RecentSeries(capacity: 300)
    public private(set) var memoryHistory = RecentSeries(capacity: 300)
    public private(set) var downHistory = RecentSeries(capacity: 300)
    public private(set) var upHistory = RecentSeries(capacity: 300)
    /// Internet round trip per probe (5 s cadence → 5 min). Timeouts are stored as NaN so charts show gaps.
    public private(set) var latencyHistory = RecentSeries(capacity: 60)
    /// Thermal state changes, newest last, capped at 50.
    public private(set) var thermalChanges: [ThermalChange] = []

    @ObservationIgnored private var processListViewers = 0

    // MARK: Alerts and timeline
    public private(set) var alertRules: [AlertRule] = []
    public private(set) var firingAlertIDs: Set<UUID> = []
    /// Events since launch, newest last (capped). Older ones are in the history store.
    public private(set) var recentEvents: [TimelineEvent] = []
    /// Called for every fired/resolved alert; the app decides whether to notify.
    @ObservationIgnored public var onAlert: ((AlertEvent) -> Void)?
    @ObservationIgnored private var alertEngine = AlertEngine()
    static let recentEventLimit = 200

    @ObservationIgnored private let sampler: Sampler
    @ObservationIgnored private let prober: Prober
    /// Nil when history is disabled (tests) or the database could not be opened.
    @ObservationIgnored public let recorder: HistoryRecorder?
    public var history: HistoryStore? { recorder?.store }

    public init(baseInterval: TimeInterval = 1, recorder: HistoryRecorder? = nil) {
        processorName = CPUCollector.processorName()
        self.recorder = recorder
        sampler = Sampler(baseInterval: baseInterval, recorder: recorder)
        prober = Prober(recorder: recorder)
        samplingInterval = baseInterval
    }

    public func start() {
        let sampler = self.sampler
        let prober = self.prober
        let recorder = self.recorder
        Task { [weak self] in
            await sampler.start { snapshot in self?.apply(snapshot) }
            await prober.start { reading in self?.apply(reading) }
            await recorder?.start()
        }
    }

    /// Writes buffered history. Call before quitting.
    public func flushHistory() async {
        await recorder?.flush()
    }

    public func stop() {
        let sampler = self.sampler
        let prober = self.prober
        Task {
            await sampler.stop()
            await prober.stop()
        }
    }

    /// Process scans run every base interval while any process list is on screen, otherwise every 5 s.
    /// Balanced calls: the popover and the dashboard can both show one.
    public func processListAppeared() {
        processListViewers += 1
        if processListViewers == 1 { setProcessesVisible(true) }
    }

    public func processListDisappeared() {
        guard processListViewers > 0 else { return }
        processListViewers -= 1
        if processListViewers == 0 { setProcessesVisible(false) }
    }

    private func setProcessesVisible(_ visible: Bool) {
        let sampler = self.sampler
        Task { await sampler.setProcessesVisible(visible) }
    }

    /// Base sampling interval (PRD §14: 1, 2 or 5 s). Also sets process-scan rate while visible.
    public func setSamplingInterval(_ interval: TimeInterval) {
        samplingInterval = interval
        let sampler = self.sampler
        Task { await sampler.setBaseInterval(interval) }
    }

    /// Ping target must be an IPv4 address (unprivileged ICMP is IPv4-only here).
    public func configureNetwork(internetTarget: String, thresholds: NetworkThresholds) {
        let prober = self.prober
        Task { await prober.configure(internetTarget: internetTarget, thresholds: thresholds) }
    }

    /// Average over the last 5 minutes of wall time, whatever the sampling interval.
    public var cpuFiveMinuteAverage: Double? {
        let count = max(1, Int((300 / samplingInterval).rounded()))
        let recent = cpuHistory.suffix(count)
        return recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
    }

    public var menuBarInputs: MenuBarInputs {
        MenuBarInputs(cpu: cpu, memory: memory, network: network, networkHealth: networkHealth,
                      battery: battery, thermal: thermal)
    }

    public func topProcesses(byCPU limit: Int) -> [ProcessRow] {
        Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }

    public func setAlertRules(_ rules: [AlertRule]) {
        alertRules = rules
        alertEngine.setRules(rules)
        firingAlertIDs = alertEngine.firingRuleIDs
    }

    /// Adds an event to the live list and the persistent timeline.
    public func post(_ event: TimelineEvent) {
        recentEvents.append(event)
        if recentEvents.count > Self.recentEventLimit { recentEvents.removeFirst(recentEvents.count - Self.recentEventLimit) }
        let recorder = self.recorder
        Task { await recorder?.record(event: event) }
    }

    func evaluateAlerts(_ values: [(AlertMetric, Double)], at now: Date) {
        guard !alertRules.isEmpty else { return }
        for (metric, value) in values {
            for event in alertEngine.evaluate(metric, value: value, at: now) {
                post(Self.timelineEvent(for: event))
                onAlert?(event)
            }
        }
        let firing = alertEngine.firingRuleIDs
        if firing != firingAlertIDs { firingAlertIDs = firing }
    }

    static func timelineEvent(for e: AlertEvent) -> TimelineEvent {
        let r = e.rule
        let comparator = switch r.comparator { case .above: ">"; case .atLeast: "≥"; case .below: "<"; case .atMost: "≤" }
        let held = r.duration > 0 ? " for \(Int(r.duration)) s" : ""
        let detail = "\(r.metric.displayName) \(r.metric.format(e.value)) · rule \(comparator) \(r.metric.format(r.threshold))\(held)"
        return TimelineEvent(time: e.time, category: .alert,
                             severity: e.kind == .fired ? r.severity.health : .healthy,
                             title: e.kind == .fired ? "\(r.name)" : "\(r.name) resolved", detail: detail)
    }

    func apply(_ reading: NetworkHealthReading) {
        networkHealth = reading
        guard reading.connectivity == .online else { return }
        latencyHistory.append(reading.internet?.latencyMs ?? .nan)
        var values: [(AlertMetric, Double)] = [(.latencyMs, reading.internet?.latencyMs ?? .infinity)]
        if let loss = reading.internet?.lossPercent { values.append((.packetLossPercent, loss)) }
        evaluateAlerts(values, at: Date())
    }

    func recordThermalChange(_ state: ThermalState, at date: Date) {
        thermalChanges.append(ThermalChange(state: state, date: date))
        if thermalChanges.count > 50 { thermalChanges.removeFirst(thermalChanges.count - 50) }
    }

    func apply(_ s: Snapshot) {
        if let v = s.cpu { cpu = v; cpuHistory.append(v.totalPercent) }
        if let v = s.memory { memory = v; memoryHistory.append(v.usedPercent) }
        if let v = s.network {
            network = v
            downHistory.append(v.downBytesPerSec)
            upHistory.append(v.upBytesPerSec)
        }
        if let v = s.disk { disk = v }
        if let v = s.battery { battery = v }
        if let v = s.thermal {
            if v != thermal { recordThermalChange(v, at: Date()) }
            thermal = v
        }
        if let v = s.processes { processes = v }
        evaluateAlerts(Self.alertValues(s), at: Date())
    }

    static func alertValues(_ s: Snapshot) -> [(AlertMetric, Double)] {
        var values: [(AlertMetric, Double)] = []
        if let v = s.cpu { values.append((.cpuPercent, v.totalPercent)) }
        if let p = s.memory?.pressure { values.append((.memoryPressure, Double(p.health.rawValue))) }
        if let d = s.disk { values.append((.diskFreeGB, Double(d.availableBytes) / 1e9)) }
        if let b = s.battery { values.append((.batteryPercent, b.percent)) }
        if let t = s.thermal { values.append((.thermalState, Double(t.rawValue))) }
        return values
    }
}

public struct ThermalChange: Sendable, Equatable, Identifiable {
    public var state: ThermalState
    public var date: Date
    public var id: Date { date }
}
