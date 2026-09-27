import Foundation
import PulseCore
import PulseCollectors
import PulseStore

/// Maps live readings to persisted history rows. Pure, so what gets stored is testable.
enum HistorySamples {
    static func from(_ s: Snapshot, at time: Date) -> [MetricSample] {
        var out: [MetricSample] = []
        func add(_ kind: MetricKind, _ value: Double?) {
            if let value { out.append(MetricSample(kind: kind, value: value, timestamp: time)) }
        }
        add(.cpuPercent, s.cpu?.totalPercent)
        add(.memoryPercent, s.memory?.usedPercent)
        add(.memoryPressure, s.memory?.pressure.map { Double($0.health.rawValue) })
        add(.swapUsedBytes, s.memory.map { Double($0.swapUsedBytes) })
        add(.networkDownBytesPerSec, s.network?.downBytesPerSec)
        add(.networkUpBytesPerSec, s.network?.upBytesPerSec)
        add(.diskFreeBytes, s.disk.map { Double($0.availableBytes) })
        add(.batteryPercent, s.battery?.percent)
        add(.thermalState, s.thermal.map { Double($0.rawValue) })
        add(.gpuPercent, s.gpu?.utilizationPercent)
        add(.cpuTemperatureC, s.sensors?.cpuCelsius)
        add(.ssdTemperatureC, s.sensors?.ssdCelsius)
        add(.batteryTemperatureC, s.sensors?.batteryCelsius)
        add(.hottestTemperatureC, s.sensors?.hottest?.celsius)
        add(.fanRPM, s.sensors?.fans.map(\.rpm).max())
        return out
    }

    static func from(_ r: NetworkHealthReading, at time: Date) -> [MetricSample] {
        guard r.connectivity == .online else { return [] }
        var out: [MetricSample] = []
        func add(_ kind: MetricKind, _ value: Double?) {
            if let value { out.append(MetricSample(kind: kind, value: value, timestamp: time)) }
        }
        add(.latencyMs, r.internet?.latencyMs)
        add(.packetLossPercent, r.internet?.lossPercent)
        add(.gatewayLatencyMs, r.gateway?.latencyMs)
        add(.secondaryLatencyMs, r.secondary?.latencyMs)
        add(.dnsLatencyMs, r.dns?.latencyMs)
        return out
    }

    /// Plan decision 6: only the top 10 by CPU and top 10 by memory are kept per scan.
    static func topProcesses(_ rows: [ProcessRow], at time: Date, limit: Int = 10) -> [ProcessSample] {
        let byCPU = rows.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit)
        let byMemory = rows.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit)
        var seen = Set<Int32>()
        return (byCPU + byMemory).compactMap { row in
            guard seen.insert(row.pid).inserted else { return nil }
            return ProcessSample(time: time, pid: row.pid, name: row.name, cpuPercent: row.cpuPercent, memoryBytes: row.memoryBytes)
        }
    }
}
