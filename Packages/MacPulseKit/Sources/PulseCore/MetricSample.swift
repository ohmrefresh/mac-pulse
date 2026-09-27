import Foundation

public enum MetricKind: String, Sendable, Codable, CaseIterable {
    case cpuPercent
    case memoryUsedBytes
    case memoryPressure
    case swapUsedBytes
    case networkDownBytesPerSec
    case networkUpBytesPerSec
    case latencyMs
    case packetLossPercent
    case dnsLatencyMs
    case diskFreeBytes
    case batteryPercent
    case thermalState
}

public struct MetricSample: Sendable, Codable, Equatable {
    public var kind: MetricKind
    public var value: Double
    public var timestamp: Date

    public init(kind: MetricKind, value: Double, timestamp: Date) {
        self.kind = kind
        self.value = value
        self.timestamp = timestamp
    }
}
