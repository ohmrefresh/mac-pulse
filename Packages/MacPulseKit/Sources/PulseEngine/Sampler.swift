import Foundation
import PulseCore
import PulseCollectors

/// Readings produced on one tick. Nil fields were not due and must not overwrite prior values.
public struct Snapshot: Sendable {
    public var cpu: CPUReading?
    public var memory: MemoryReading?
    public var network: NetworkReading?
    public var disk: DiskReading?
    public var battery: BatteryReading?
    public var thermal: ThermalState?
    public var processes: [ProcessRow]?
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
    private var loop: Task<Void, Never>?

    init(baseInterval: TimeInterval) {
        cadence = Cadence(baseInterval: baseInterval)
    }

    func start(publish: @escaping @Sendable @MainActor (Snapshot) -> Void) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.tick()
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

    /// Takes effect from the next sleep; the loop re-reads the interval every iteration.
    func setBaseInterval(_ interval: TimeInterval) {
        cadence.baseInterval = interval
    }

    private func tick() -> Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let due = cadence.due(at: now)
        var s = Snapshot()
        if due.contains(.fast) {
            s.cpu = cpu.sample()
            s.memory = memory.sample()
            s.network = network.sample(now: now)
        }
        if due.contains(.power) {
            s.battery = battery.sample()
            s.thermal = thermal.sample()
        }
        if due.contains(.disk) {
            s.disk = disk.sample()
        }
        if due.contains(.processes) {
            s.processes = processes.sample(refreshPrivileged: due.contains(.privilegedProcesses), now: now)
        }
        return s
    }
}
