import Foundation

/// Persisted metric identifiers. Raw values are stored in history — never rename a case; add new ones.
public enum MetricKind: String, Sendable, Codable, CaseIterable {
    case cpuPercent = "cpu"
    case memoryPercent = "mem"
    /// HealthLevel raw value of the memory pressure (1 healthy … 3 critical).
    case memoryPressure = "mem_pressure"
    case swapUsedBytes = "swap"
    case networkDownBytesPerSec = "net_down"
    case networkUpBytesPerSec = "net_up"
    case latencyMs = "latency"
    case gatewayLatencyMs = "gw_latency"
    case secondaryLatencyMs = "latency2"
    case packetLossPercent = "loss"
    case dnsLatencyMs = "dns"
    case diskFreeBytes = "disk_free"
    case batteryPercent = "battery"
    /// ThermalState raw value (0 nominal … 3 critical).
    case thermalState = "thermal"
    case gpuPercent = "gpu"
    /// Hottest CPU die, °C (private API, ADR 0002).
    case cpuTemperatureC = "cpu_temp"
    /// Fastest fan, RPM (private API, ADR 0002).
    case fanRPM = "fan_rpm"
    /// SSD (NAND) sensor, °C (private API, ADR 0002).
    case ssdTemperatureC = "ssd_temp"
    /// Battery gas-gauge sensor, °C (private API, ADR 0002).
    case batteryTemperatureC = "battery_temp"
    /// Warmest of all temperature sensors, °C (private API, ADR 0002).
    case hottestTemperatureC = "hottest_temp"
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
