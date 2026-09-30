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
    /// Mounted Volumes, startup disk first. Live only; refreshed with the disk job (60 s, or on mount/unmount).
    public private(set) var volumes: [DiskReading] = []
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
    public private(set) var loadAverage: LoadAverage?
    /// CPU frequency and GPU power (private APIs, ADR 0003). Nil unless the Performance page is
    /// visible, and individually nil for anything this Mac does not report.
    public private(set) var frequency: FrequencyReading?
    /// Wi‑Fi signal and generation. Nil unless the Network page is visible and the primary link is Wi‑Fi.
    public private(set) var wifi: WiFiReading?
    public let processorName: String?
    /// A laptop: decides "MacBook" vs "Mac" in the sidebar. Read once at launch.
    public let hasInternalBattery: Bool
    /// Fixed for the life of the process; `performanceCores`/`efficiencyCores` are nil on Intel.
    public let cpuTopology: CPUTopology
    @ObservationIgnored private let bootTime: Date?

    /// Nil if `kern.boottime` could not be read.
    public var uptime: TimeInterval? {
        bootTime.map { Date().timeIntervalSince($0) }
    }

    public private(set) var samplingInterval: TimeInterval

    /// When the last fast (CPU) sample arrived. Not observed: a view that shows freshness polls it,
    /// so the every-second write does not invalidate anything.
    @ObservationIgnored public private(set) var lastSampleAt: Date?

    /// Up to 300 samples (5 min at 1 s): sparklines use the tail, cards show averages.
    public private(set) var cpuHistory = RecentSeries(capacity: 300)
    public private(set) var memoryHistory = RecentSeries(capacity: 300)
    public private(set) var downHistory = RecentSeries(capacity: 300)
    public private(set) var upHistory = RecentSeries(capacity: 300)
    /// GPU % per GPU sample — 1 s while the Performance page is visible, else 5 s (`gpuInterval`).
    public private(set) var gpuHistory = RecentSeries(capacity: 300)
    /// One-minute load average per fast sample.
    public private(set) var loadHistory = RecentSeries(capacity: 300)
    /// Memory Used split into its parts, for the stacked Live chart. Same cadence as `memoryHistory`.
    public private(set) var memoryAppHistory = RecentSeries(capacity: 300)
    public private(set) var memoryWiredHistory = RecentSeries(capacity: 300)
    public private(set) var memoryCompressedHistory = RecentSeries(capacity: 300)
    public private(set) var memoryCachedHistory = RecentSeries(capacity: 300)
    /// One series per logical core, rebuilt if the core count ever changes.
    public private(set) var perCoreHistory: [RecentSeries] = []
    /// Battery percent per battery sample (5 s cadence → 10 min).
    public private(set) var batteryHistory = RecentSeries(capacity: 120)
    /// °C per sensor sample (5–60 s cadence depending on visibility), timestamped for 15-min changes.
    public private(set) var temperatureHistory = TimedSeries(capacity: 240)
    public private(set) var ssdTemperatureHistory = TimedSeries(capacity: 240)
    public private(set) var batteryTemperatureHistory = TimedSeries(capacity: 240)
    public private(set) var hottestTemperatureHistory = TimedSeries(capacity: 240)
    /// Lowest and highest reading of each Sensor since launch, by sensor name.
    public private(set) var sensorExtremes: [String: ClosedRange<Double>] = [:]
    /// Debounced CPU Health Level from the user's CPU thresholds; matches the timeline.
    public private(set) var cpuHealth: HealthLevel?
    /// Internet round trip per probe (5 s cadence → 5 min). Timeouts are stored as NaN so charts show gaps.
    public private(set) var latencyHistory = RecentSeries(capacity: 60)
    /// The rest of the Path, same cadence and NaN convention. A probe that does not exist (no IPv4
    /// router, no DNS reading) appends nothing, so it never reads as loss.
    public private(set) var gatewayLatencyHistory = RecentSeries(capacity: 60)
    /// One series per Comparison Target, keyed by the target as typed; pruned when a target is removed.
    public private(set) var comparisonLatencyHistories: [String: RecentSeries] = [:]
    /// The internet targets being probed (sanitized), Primary first.
    public private(set) var probeTargets = ProbeTargets.defaults
    public private(set) var dnsLatencyHistory = RecentSeries(capacity: 60)
    /// Thermal state changes, newest last, capped at 50.
    public private(set) var thermalChanges: [ThermalChange] = []

    @ObservationIgnored private var processListViewers = 0
    @ObservationIgnored private var sensorViewers = 0
    @ObservationIgnored private var developerViewers = 0
    @ObservationIgnored private var performanceViewers = 0
    @ObservationIgnored private var networkViewers = 0
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
    /// Set while saving history keeps failing (disk full, permissions, corruption); nil when healthy.
    public private(set) var historyError: String?

    public init(baseInterval: TimeInterval = 1, recorder: HistoryRecorder? = nil) {
        processorName = CPUCollector.processorName()
        hasInternalBattery = BatteryCollector.hasInternalBattery()
        cpuTopology = SystemInfoCollector.topology()
        bootTime = SystemInfoCollector.bootTime()
        self.recorder = recorder
        sampler = Sampler(baseInterval: baseInterval, recorder: recorder)
        prober = Prober(recorder: recorder)
        samplingInterval = baseInterval
    }

    public func start() {
        let sampler = self.sampler
        let prober = self.prober
        let recorder = self.recorder
        post(Self.monitoringStartedEvent(at: Date()))
        Task { [weak self] in
            await recorder?.setErrorHandler { message in
                Task { @MainActor in self?.historyError = message }
            }
        }
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

    /// The Performance page samples the GPU every base interval instead of every 5 s while it is visible.
    /// Reference-counted, like the process-list and sensor gates.
    public func performanceAppeared() {
        performanceViewers += 1
        if performanceViewers == 1 { let sampler = self.sampler; Task { await sampler.setPerformanceVisible(true) } }
    }

    public func performanceDisappeared() {
        guard performanceViewers > 0 else { return }
        performanceViewers -= 1
        if performanceViewers == 0 {
            frequency = nil                     // stale once the subscription is released
            let sampler = self.sampler
            Task { await sampler.setPerformanceVisible(false) }
        }
    }

    /// Wi‑Fi details are read every 5 s only while the Network page is visible. Reference-counted, like the
    /// performance gate; the reading is cleared when the last viewer goes away.
    public func networkAppeared() {
        networkViewers += 1
        if networkViewers == 1 { let sampler = self.sampler; Task { await sampler.setNetworkVisible(true) } }
    }

    public func networkDisappeared() {
        guard networkViewers > 0 else { return }
        networkViewers -= 1
        if networkViewers == 0 {
            wifi = nil
            let sampler = self.sampler
            Task { await sampler.setNetworkVisible(false) }
        }
    }

    /// Seconds between GPU samples right now — charts need their own series' spacing, not `samplingInterval`.
    public var gpuInterval: TimeInterval { performanceViewers > 0 ? samplingInterval : 5 }

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

    /// Internet targets (sanitized to 1–4 valid, distinct entries; the first is the Primary Target) and
    /// network thresholds. An edit to the list after the first call is logged on the timeline.
    public func configureNetwork(targets: [ProbeTarget], thresholds: NetworkThresholds) {
        let targets = ProbeTargets.sanitized(targets)
        diagnosticsConfig.network = thresholds
        latencyThreshold = thresholds.latencyMs
        for event in timeline.observe(targets: targets, at: Date()) { post(event) }
        if targets != probeTargets { probeTargets = targets }
        let keep = Set(targets.dropFirst().map(\.address))
        if comparisonLatencyHistories.keys.contains(where: { !keep.contains($0) }) {
            comparisonLatencyHistories = comparisonLatencyHistories.filter { keep.contains($0.key) }
        }
        let prober = self.prober
        Task { await prober.configure(targets: targets, thresholds: thresholds) }
    }

    /// The user's latency bands (Settings), as last passed to `configureNetwork`. Observed, so the
    /// Network page's bands move as soon as Settings change.
    public private(set) var latencyThreshold = NetworkThresholds().latencyMs

    /// Average over the last 5 minutes of wall time, whatever the sampling interval.
    public var cpuFiveMinuteAverage: Double? {
        cpuHistory.average(lastSeconds: 300, interval: samplingInterval)
    }

    /// Card deltas: current value minus its 5-minute average. Nil until the series spans 2.5 min.
    public var cpuTrend: Double? { cpuHistory.trend(interval: samplingInterval) }
    public var memoryTrend: Double? { memoryHistory.trend(interval: samplingInterval) }
    public var gpuTrend: Double? { gpuHistory.trend(interval: gpuInterval) }
    public var temperatureTrend: Double? { temperatureHistory.trend() }

    /// Highest CPU % over the last 5 minutes of wall time.
    public var cpuFiveMinutePeak: Double? {
        cpuHistory.suffix(max(1, Int((300 / samplingInterval).rounded()))).max()
    }

    /// Bytes received and sent over the last 5 minutes of the live buffer.
    public var transferredLast5Minutes: (down: Double, up: Double) {
        (Transferred.bytes(rates: downHistory.values, interval: samplingInterval),
         Transferred.bytes(rates: upHistory.values, interval: samplingInterval))
    }

    /// Highest throughput in the live buffer and roughly when it happened.
    public var peakDown: (bytesPerSec: Double, time: Date)? { peak(of: downHistory) }
    public var peakUp: (bytesPerSec: Double, time: Date)? { peak(of: upHistory) }

    private func peak(of series: RecentSeries) -> (bytesPerSec: Double, time: Date)? {
        let values = series.values
        guard let p = Peak.of(values) else { return nil }
        // Throughput arrives on the fast tick with the CPU, so the newest sample is at `lastSampleAt`.
        let newest = lastSampleAt ?? Date()
        return (p.value, newest.addingTimeInterval(-Double(values.count - 1 - p.index) * samplingInterval))
    }

    /// Hedged one-line reading of the live Path series, using the user's diagnostics and latency limits.
    public var pathInsight: (text: String, level: HealthLevel)? {
        let comparisons = (networkHealth?.comparisons ?? []).compactMap { c in
            comparisonLatencyHistories[c.host ?? c.address].map { (name: c.displayName, stats: LatencyStats($0.values)) }
        }
        return PathInsight.evaluate(gateway: LatencyStats(gatewayLatencyHistory.values),
                                    internet: LatencyStats(latencyHistory.values),
                                    comparisons: comparisons,
                                    dns: LatencyStats(dnsLatencyHistory.values),
                                    config: diagnosticsConfig, latencyWarningMs: diagnosticsConfig.network.latencyMs.warning)
    }

    public var menuBarInputs: MenuBarInputs {
        MenuBarInputs(cpu: cpu, memory: memory, network: network, networkHealth: networkHealth,
                      battery: battery, thermal: thermal, cpuCelsius: sensors?.cpuCelsius, gpuPercent: gpu?.utilizationPercent)
    }

    public func topProcesses(byCPU limit: Int) -> [ProcessRow] {
        Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }

    public func topProcesses(byMemory limit: Int) -> [ProcessRow] {
        Array(processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit))
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
            targets: probeTargets,
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

    nonisolated static func monitoringStartedEvent(at now: Date) -> TimelineEvent {
        TimelineEvent(time: now, category: .system, severity: .healthy, title: TimelineEpisodes.monitoringStartedTitle)
    }

    static func timelineEvent(for e: AlertEvent) -> TimelineEvent {
        let r = e.rule
        let comparator = switch r.comparator { case .above: ">"; case .atLeast: "≥"; case .below: "<"; case .atMost: "≤" }
        let held = r.duration > 0 ? " for \(Int(r.duration)) s" : ""
        let detail = "\(r.metric.displayName) \(r.metric.format(e.value)) · rule \(comparator) \(r.metric.format(r.threshold))\(held)"
        return TimelineEvent(time: e.time, category: .alert,
                             severity: e.kind == .fired ? r.severity.health : .healthy,
                             title: e.kind == .fired ? "\(r.name)" : "\(r.name)\(TimelineEpisodes.resolvedSuffix)", detail: detail)
    }

    func apply(_ reading: NetworkHealthReading) {
        networkHealth = reading
        let now = Date()
        for event in timeline.observe(reading, interface: network?.interface, at: now) { post(event) }
        guard reading.connectivity == .online else { return }
        // Can't-resolve is not a timeout: it appends nothing, so it never reads as loss.
        if reading.internet?.unresolved != true { latencyHistory.append(reading.internet?.latencyMs ?? .nan) }
        if let g = reading.gateway { gatewayLatencyHistory.append(g.latencyMs ?? .nan) }
        for c in reading.comparisons where !c.unresolved {
            comparisonLatencyHistories[c.host ?? c.address, default: RecentSeries(capacity: 60)].append(c.latencyMs ?? .nan)
        }
        if let d = reading.dns { dnsLatencyHistory.append(d.latencyMs ?? .nan) }
        var values: [(AlertMetric, Double)] = []
        if reading.internet?.unresolved != true { values.append((.latencyMs, reading.internet?.latencyMs ?? .infinity)) }
        if let loss = reading.internet?.lossPercent { values.append((.packetLossPercent, loss)) }
        evaluateAlerts(values, at: now)
    }

    func recordThermalChange(_ state: ThermalState, at date: Date) {
        thermalChanges.append(ThermalChange(state: state, date: date))
        if thermalChanges.count > 50 { thermalChanges.removeFirst(thermalChanges.count - 50) }
    }

    func apply(_ s: Snapshot) {
        if let v = s.cpu {
            cpu = v
            lastSampleAt = Date()
            cpuHistory.append(v.totalPercent)
            if perCoreHistory.count != v.perCorePercent.count {
                perCoreHistory = v.perCorePercent.map { _ in RecentSeries(capacity: 300) }
            }
            for (index, value) in v.perCorePercent.enumerated() { perCoreHistory[index].append(value) }
        }
        if let v = s.memory {
            memory = v
            memoryHistory.append(v.usedPercent)
            let total = Double(max(v.totalBytes, 1))
            memoryAppHistory.append(Double(v.appBytes) / total * 100)
            memoryWiredHistory.append(Double(v.wiredBytes) / total * 100)
            memoryCompressedHistory.append(Double(v.compressedBytes) / total * 100)
            memoryCachedHistory.append(Double(v.cachedFilesBytes) / total * 100)
        }
        if let v = s.loadAverage { loadAverage = v; loadHistory.append(v.oneMinute) }
        if let v = s.frequency { frequency = v }
        if let v = s.network {
            network = v
            if v.interfaceKind != NetworkCollector.wifiKind, wifi != nil { wifi = nil }
            downHistory.append(v.downBytesPerSec)
            upHistory.append(v.upBytesPerSec)
        }
        if let v = s.disk { disk = v }
        if let v = s.volumes, v != volumes { volumes = v }
        if let v = s.battery { battery = v; batteryHistory.append(v.percent) }
        if let v = s.thermal {
            if v != thermal { recordThermalChange(v, at: Date()) }
            thermal = v
        }
        if let v = s.processes { processes = v }
        if let v = s.gpu { gpu = v; gpuHistory.append(v.utilizationPercent) }
        if let v = s.sensors { applySensors(v, at: Date()) }
        if let v = s.peripheralBatteries { peripheralBatteries = v }
        if let v = s.wifi, networkViewers > 0, v != wifi { wifi = v }
        let now = Date()
        for event in timeline.observe(s, at: now) { post(event) }
        if s.cpu != nil { cpuHealth = timeline.reportedHealth(.cpu) }
        evaluateAlerts(Self.alertValues(s), at: now)
    }

    func applySensors(_ v: SensorsReading, at now: Date) {
        sensors = v
        if let c = v.cpuCelsius { temperatureHistory.append(c, at: now) }
        if let c = v.ssdCelsius { ssdTemperatureHistory.append(c, at: now) }
        if let c = v.batteryCelsius { batteryTemperatureHistory.append(c, at: now) }
        if let c = v.hottest?.celsius { hottestTemperatureHistory.append(c, at: now) }
        for sensor in v.sensors {
            let r = sensorExtremes[sensor.name]
            sensorExtremes[sensor.name] = min(r?.lowerBound ?? sensor.celsius, sensor.celsius)...max(r?.upperBound ?? sensor.celsius, sensor.celsius)
        }
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
