import Foundation

/// Metrics an alert rule can watch (PRD §11).
public enum AlertMetric: String, Codable, Sendable, CaseIterable {
    case cpuPercent
    /// Health Level raw value of memory pressure: 1 healthy, 2 warning, 3 critical.
    case memoryPressure
    case diskFreeGB
    /// Internet round trip; a probe timeout counts as +∞.
    case latencyMs
    case packetLossPercent
    case batteryPercent
    /// Thermal State raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    case thermalState
}

public enum AlertComparator: String, Codable, Sendable, CaseIterable {
    case above, atLeast, below, atMost

    public func matches(_ value: Double, _ threshold: Double) -> Bool {
        switch self {
        case .above: value > threshold
        case .atLeast: value >= threshold
        case .below: value < threshold
        case .atMost: value <= threshold
        }
    }
}

public enum AlertSeverity: String, Codable, Sendable, CaseIterable {
    case warning, critical

    public var health: HealthLevel { self == .warning ? .warning : .critical }
}

/// A user-configurable condition — metric, comparator, threshold, duration, severity.
public struct AlertRule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var metric: AlertMetric
    public var comparator: AlertComparator
    public var threshold: Double
    /// Seconds the condition must hold to fire, and be false to resolve. 0 = immediate.
    public var duration: TimeInterval
    public var severity: AlertSeverity
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, metric: AlertMetric, comparator: AlertComparator,
                threshold: Double, duration: TimeInterval, severity: AlertSeverity, isEnabled: Bool) {
        self.id = id
        self.name = name
        self.metric = metric
        self.comparator = comparator
        self.threshold = threshold
        self.duration = duration
        self.severity = severity
        self.isEnabled = isEnabled
    }

    /// PRD §12 templates. Seeded disabled: notification permission is asked when the user first enables one.
    public static let templates: [AlertRule] = [
        AlertRule(name: "High CPU", metric: .cpuPercent, comparator: .above, threshold: 90,
                  duration: 30, severity: .warning, isEnabled: false),
        AlertRule(name: "Memory Pressure", metric: .memoryPressure, comparator: .atLeast,
                  threshold: Double(HealthLevel.critical.rawValue), duration: 15, severity: .critical, isEnabled: false),
        AlertRule(name: "Internet Latency", metric: .latencyMs, comparator: .above, threshold: 300,
                  duration: 20, severity: .warning, isEnabled: false),
        AlertRule(name: "Packet Loss", metric: .packetLossPercent, comparator: .above, threshold: 10,
                  duration: 0, severity: .critical, isEnabled: false),
        AlertRule(name: "Low Disk", metric: .diskFreeGB, comparator: .below, threshold: 10,
                  duration: 0, severity: .warning, isEnabled: false),
        AlertRule(name: "Thermal Warning", metric: .thermalState, comparator: .atLeast,
                  threshold: Double(ThermalState.serious.rawValue), duration: 0, severity: .warning, isEnabled: false),
    ]
}
