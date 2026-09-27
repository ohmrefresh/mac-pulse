import Foundation

public enum SamplingJob: CaseIterable, Sendable, Hashable {
    /// CPU, memory, network throughput.
    case fast
    /// Battery and thermal state.
    case power
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
    private var lastRun: [SamplingJob: TimeInterval] = [:]

    public init(baseInterval: TimeInterval = 1) {
        self.baseInterval = baseInterval
    }

    public func interval(for job: SamplingJob) -> TimeInterval {
        switch job {
        case .fast: baseInterval
        case .power: 5
        case .disk: 60
        case .processes: processesVisible ? baseInterval : 5
        case .privilegedProcesses: 5
        case .sensors: sensorsVisible ? 5 : 60
        }
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
