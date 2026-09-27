import Foundation

public enum SamplingJob: CaseIterable, Sendable, Hashable {
    /// CPU, memory, network throughput.
    case fast
    /// Battery and thermal state.
    case power
    /// GPU utilization, and (while visible) frequency and GPU power.
    case gpu
    case disk
    /// Directly readable processes.
    case processes
    /// Root/system processes via `ps`.
    case privilegedProcesses
    /// Temperatures and fans (private APIs, ~20 ms per read).
    case sensors
}

/// Decides which jobs are due on a tick. Pure so the schedule is testable without a clock.
public struct Cadence: Sendable {
    public var baseInterval: TimeInterval
    public var processesVisible = false
    public var sensorsVisible = false
    /// Performance page on screen: the GPU ticks with the other cards instead of every 5 s.
    public var performanceVisible = false
    /// Menu bar shows °C: refresh often enough to be meaningful, cheaply enough for the idle budget.
    public var sensorsInMenuBar = false
    private var lastRun: [SamplingJob: TimeInterval] = [:]

    public init(baseInterval: TimeInterval = 1) {
        self.baseInterval = baseInterval
    }

    public func interval(for job: SamplingJob) -> TimeInterval {
        switch job {
        case .fast: baseInterval
        case .power: 5
        case .gpu: performanceVisible ? baseInterval : 5
        case .disk: 60
        case .processes: processesVisible ? baseInterval : 5
        case .privilegedProcesses: 5
        case .sensors: sensorsVisible ? 5 : (sensorsInMenuBar ? 15 : 60)
        }
    }

    /// Makes `job` due on the next tick (used when a system notification says its value changed).
    public mutating func expedite(_ job: SamplingJob) {
        lastRun[job] = nil
    }

    /// Jobs due at `now`; marks them as run. Half a base interval of slack absorbs timer jitter.
    public mutating func due(at now: TimeInterval) -> Set<SamplingJob> {
        var due = Set<SamplingJob>()
        for job in SamplingJob.allCases {
            if let last = lastRun[job], now - last < interval(for: job) - baseInterval / 2 { continue }
            due.insert(job)
            lastRun[job] = now
        }
        return due
    }
}
