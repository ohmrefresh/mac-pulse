import Foundation
import PulseCore
import PulseCollectors
import PulseStore

/// Readings produced on one tick. Nil fields were not due and must not overwrite prior values.
public struct Snapshot: Sendable {
    public var cpu: CPUReading?
    public var memory: MemoryReading?
    public var network: NetworkReading?
    public var disk: DiskReading?
    public var battery: BatteryReading?
    public var thermal: ThermalState?
    public var processes: [ProcessRow]?
    public var gpu: GPUReading?
    public var sensors: SensorsReading?
    public var loadAverage: LoadAverage?
    public var frequency: FrequencyReading?
    public var peripheralBatteries: [PeripheralBattery]?
    public var wifi: WiFiReading?
}

/// The single clock driving every collector, off the main thread.
actor Sampler {
    private var cadence: Cadence
    private var cpu = CPUCollector()
    private let memory = MemoryCollector()
    private var network = NetworkCollector()
    private let disk = DiskCollector()
    private let battery = BatteryCollector()
    private let thermal = ThermalCollector()
    private var processes = ProcessCollector()
    private let sensors = SensorsCollector()
    /// Created on demand while the Performance page is visible, released when it goes away (ADR 0003).
    private var ioReport: IOReportClient?
    /// Network page on screen: the only time Wi‑Fi details are read.
    private var networkVisible = false
    private var lastNetwork: NetworkReading?
    private var loop: Task<Void, Never>?
    private let recorder: HistoryRecorder?

    init(baseInterval: TimeInterval, recorder: HistoryRecorder?) {
        cadence = Cadence(baseInterval: baseInterval)
        self.recorder = recorder
    }

    func start(publish: @escaping @Sendable @MainActor (Snapshot) -> Void) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.tick()
                await self.record(snapshot)
                await publish(snapshot)
                let interval = await self.cadence.baseInterval
                // Tolerance lets the OS coalesce wakeups with other timers (energy budget).
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.1))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func setProcessesVisible(_ visible: Bool) {
        cadence.processesVisible = visible
    }

    func setSensorsVisible(_ visible: Bool) {
        cadence.sensorsVisible = visible
    }

    /// Performance page visibility: speeds up the GPU job and owns the IOReport subscription,
    /// so a menu-bar-only session never pays for frequency or GPU power it does not display.
    func setPerformanceVisible(_ visible: Bool) {
        cadence.performanceVisible = visible
        ioReport = visible ? IOReportClient() : nil
    }

    func setNetworkVisible(_ visible: Bool) {
        networkVisible = visible
        if visible { cadence.expedite(.wifi) }   // don't wait up to 5 s for the first reading
    }

    func setSensorsInMenuBar(_ value: Bool) {
        cadence.sensorsInMenuBar = value
    }

    func expedite(_ jobs: Set<SamplingJob>) {
        for job in jobs { cadence.expedite(job) }
    }

    /// Takes effect from the next sleep; the loop re-reads the interval every iteration.
    func setBaseInterval(_ interval: TimeInterval) {
        cadence.baseInterval = interval
    }

    private func record(_ snapshot: Snapshot) async {
        guard let recorder else { return }
        let now = Date()
        await recorder.record(HistorySamples.from(snapshot, at: now))
        if let processes = snapshot.processes {
            await recorder.record(processes: HistorySamples.topProcesses(processes, at: now))
        }
    }

    private func tick() -> Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let due = cadence.due(at: now)
        var s = Snapshot()
        if due.contains(.fast) {
            s.cpu = cpu.sample()
            s.memory = memory.sample()
            s.network = network.sample(now: now)
            lastNetwork = s.network
            s.loadAverage = SystemInfoCollector.loadAverage()
        }
        if due.contains(.power) {
            s.battery = battery.sample()
            s.thermal = thermal.sample()
        }
        if due.contains(.gpu) {
            s.gpu = GPUCollector.sample()
            s.frequency = ioReport?.sample(now: now)
        }
        if due.contains(.disk) {
            s.disk = disk.sample()
            s.peripheralBatteries = PeripheralBatteryCollector.sample()
        }
        if due.contains(.sensors) {
            s.sensors = sensors.sample()
        }
        if due.contains(.wifi), networkVisible, lastNetwork?.interfaceKind == NetworkCollector.wifiKind,
           let name = lastNetwork?.interface {
            // An empty reading, not nil, when CoreWLAN has nothing: nil would keep the previous values.
            s.wifi = WiFiCollector.sample(interface: name) ?? WiFiReading(rssiDBm: nil, phy: nil)
        }
        if due.contains(.processes) {
            s.processes = processes.sample(refreshPrivileged: due.contains(.privilegedProcesses), now: now)
        }
        return s
    }
}
