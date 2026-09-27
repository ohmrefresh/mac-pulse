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
    public private(set) var gpu: GPUReading?
    /// Nil until the first read; empty when the private sensor APIs are unavailable (ADR 0002).
    public private(set) var sensors: SensorsReading?
    public private(set) var peripheralBatteries: [PeripheralBattery] = []
    public private(set) var developer = DeveloperSnapshot()
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
    @ObservationIgnored private var sensorViewers = 0
    @ObservationIgnored private var developerViewers = 0
    @ObservationIgnored private let developerMonitor = DeveloperMonitor()

    // MARK: Alerts and timeline
    public private(set) var alertRules: [AlertRule] = []
    public private(set) var firingAlertIDs: Set<UUID> = []
    /// Events since launch, newest last (capped). Older ones are in the history store.
    public private(set) var recentEvents: [TimelineEvent] = []
    /// Called for every fired/resolved alert; the app decides whether to notify.
    @ObservationIgnored public var onAlert: ((AlertEvent) -> Void)?
    @ObservationIgnored private var alertEngine = AlertEngine()
    @ObservationIgnored private var timeline = TimelineGenerator()
    @ObservationIgnored private var diagnosticsConfig = DiagnosticsConfig()
    @ObservationIgnored private var systemEvents: SystemEventSources?
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
        post(TimelineEvent(time: Date(), category: .system, severity: .healthy, title: "Monitoring started"))
        systemEvents = SystemEventSources { [weak self] jobs in self?.expedite(jobs) }
        Task { [weak self] in
            await sampler.start { snapshot in self?.apply(snapshot) }
            await prober.start { reading in self?.apply(reading) }
            await self?.developerMonitor.start { snapshot in self?.apply(snapshot) }
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
        let developerMonitor = self.developerMonitor
        Task {
            await sampler.stop()
            await prober.stop()
            await developerMonitor.stop()
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

    /// Docker stats and listening ports are only collected while the Developer view is visible.
    public func developerAppeared() {
        developerViewers += 1
        if developerViewers == 1 { let m = developerMonitor; Task { await m.setVisible(true) } }
    }

    public func developerDisappeared() {
        guard developerViewers > 0 else { return }
        developerViewers -= 1
        if developerViewers == 0 { let m = developerMonitor; Task { await m.setVisible(false) } }
    }

    /// Decision D1: off by default; contacts 1.1.1.1 only on network change or every 30 min.
    public func setPublicIPEnabled(_ enabled: Bool) {
        let m = developerMonitor
        Task { await m.setPublicIPEnabled(enabled) }
    }

    func apply(_ snapshot: DeveloperSnapshot) {
        let now = Date()
        for event in DeveloperMonitor.containerEvents(old: developer.containers, new: snapshot.containers, at: now) {
            post(event)
        }
        if let config = snapshot.networkConfig {
            for event in timeline.observe(config: config, at: now) { post(event) }
        }
        if snapshot != developer { developer = snapshot }
    }

    /// Temperatures refresh every 5 s while any view showing them is on screen, else every 60 s.
    public func sensorsAppeared() {
        sensorViewers += 1
        if sensorViewers == 1 { let sampler = self.sampler; Task { await sampler.setSensorsVisible(true) } }
    }

    public func sensorsDisappeared() {
        guard sensorViewers > 0 else { return }
        sensorViewers -= 1
        if sensorViewers == 0 { let sampler = self.sampler; Task { await sampler.setSensorsVisible(false) } }
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
    /// CPU Health Level thresholds, used by the timeline and diagnostics (user-configurable).
    public func setCPUThresholds(_ threshold: Threshold) {
        timeline.config.cpu = threshold
        diagnosticsConfig.cpu = threshold
    }

    /// User-configurable diagnostics limits. Network latency/loss come from `configureNetwork`.
    public func setDiagnosticsLimits(gatewayLatencyMs: Double, dnsSlowMs: Double, lowDiskGB: Double, hotCPUCelsius: Double) {
        diagnosticsConfig.gatewayLatencyMs = gatewayLatencyMs
        diagnosticsConfig.dnsSlowMs = dnsSlowMs
        diagnosticsConfig.lowDiskBytes = lowDiskGB * 1e9
        diagnosticsConfig.hotCPUCelsius = hotCPUCelsius
    }

    /// Refresh sensors every 15 s while the menu bar shows °C.
    public func setMenuBarShowsTemperature(_ value: Bool) {
        let sampler = self.sampler
        Task { await sampler.setSensorsInMenuBar(value) }
    }

    /// Samples these jobs on the next tick instead of waiting for their cadence.
    public func expedite(_ jobs: Set<SamplingJob>) {
        let sampler = self.sampler
        Task { await sampler.expedite(jobs) }
    }

    public func configureNetwork(internetTarget: String, thresholds: NetworkThresholds) {
        diagnosticsConfig.network = thresholds
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
                      battery: battery, thermal: thermal, cpuCelsius: sensors?.cpuCelsius, gpuPercent: gpu?.utilizationPercent)
    }

    public func topProcesses(byCPU limit: Int) -> [ProcessRow] {
        Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }

    public func setAlertRules(_ rules: [AlertRule]) {
        alertRules = rules
        alertEngine.setRules(rules)
        firingAlertIDs = alertEngine.firingRuleIDs
    }

    /// PRD §10 "Run Diagnostics": last 15 min of history plus a fresh probe burst (~1–2 s).
    public func runDiagnostics() async -> DiagnosticReport {
        await recorder?.flush()   // include samples still in the write buffer
        let live = DiagnosticsRunner.Live(
            memoryUsedPercent: memory?.usedPercent,
            diskFreeBytes: disk.map { Double($0.availableBytes) },
            primaryTarget: networkHealth?.internet?.address ?? "1.1.1.1",
            cpuFallback: cpuHistory.values)
        return await DiagnosticsRunner.run(history: history, live: live, config: diagnosticsConfig)
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
        let now = Date()
        for event in timeline.observe(reading, interface: network?.interface, at: now) { post(event) }
        guard reading.connectivity == .online else { return }
        latencyHistory.append(reading.internet?.latencyMs ?? .nan)
        var values: [(AlertMetric, Double)] = [(.latencyMs, reading.internet?.latencyMs ?? .infinity)]
        if let loss = reading.internet?.lossPercent { values.append((.packetLossPercent, loss)) }
        evaluateAlerts(values, at: now)
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
        if let v = s.gpu { gpu = v }
        if let v = s.sensors { sensors = v }
        if let v = s.peripheralBatteries { peripheralBatteries = v }
        let now = Date()
        for event in timeline.observe(s, at: now) { post(event) }
        evaluateAlerts(Self.alertValues(s), at: now)
    }

    static func alertValues(_ s: Snapshot) -> [(AlertMetric, Double)] {
        var values: [(AlertMetric, Double)] = []
        if let v = s.cpu { values.append((.cpuPercent, v.totalPercent)) }
        if let p = s.memory?.pressure { values.append((.memoryPressure, Double(p.health.rawValue))) }
        if let d = s.disk { values.append((.diskFreeGB, Double(d.availableBytes) / 1e9)) }
        if let b = s.battery { values.append((.batteryPercent, b.percent)) }
        if let t = s.thermal { values.append((.thermalState, Double(t.rawValue))) }
        if let c = s.sensors?.cpuCelsius { values.append((.cpuTemperatureC, c)) }
        if let g = s.gpu { values.append((.gpuPercent, g.utilizationPercent)) }
        return values
    }
}

public struct ThermalChange: Sendable, Equatable, Identifiable {
    public var state: ThermalState
    public var date: Date
    public var id: Date { date }
}
