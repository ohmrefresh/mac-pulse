import Foundation

/// PRD §9 timeline categories, plus alerts. Raw values are persisted — never rename.
public enum TimelineCategory: String, Codable, Sendable, CaseIterable {
    case cpu, memory, network, disk, battery, thermal, connectivity, process, system, alert
}

/// A recorded moment something changed.
public struct TimelineEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var time: Date
    public var category: TimelineCategory
    public var severity: HealthLevel
    public var title: String
    public var detail: String?

    public init(id: UUID = UUID(), time: Date, category: TimelineCategory, severity: HealthLevel,
                title: String, detail: String? = nil) {
        self.id = id
        self.time = time
        self.category = category
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

extension AlertMetric {
    public var displayName: String {
        switch self {
        case .cpuPercent: "CPU"
        case .memoryPressure: "Memory pressure"
        case .diskFreeGB: "Free disk"
        case .latencyMs: "Internet latency"
        case .packetLossPercent: "Packet loss"
        case .batteryPercent: "Battery"
        case .thermalState: "Thermal state"
        }
    }

    public func format(_ value: Double) -> String {
        guard value.isFinite else { return "timeout" }
        switch self {
        case .cpuPercent, .packetLossPercent, .batteryPercent: return "\(Int(value.rounded()))%"
        case .diskFreeGB: return String(format: "%.1f GB", value)
        case .latencyMs: return "\(Int(value.rounded())) ms"
        case .memoryPressure: return (HealthLevel(rawValue: Int(value)).map { "\($0)".capitalized }) ?? "\(value)"
        case .thermalState: return (ThermalState(rawValue: Int(value)).map { "\($0)".capitalized }) ?? "\(value)"
        }
    }
}
