/// Upper-bound thresholds: values at or above `warning` are Warning, at or above `critical` are Critical.
public struct Threshold: Sendable, Codable, Equatable {
    public var warning: Double
    public var critical: Double

    public init(warning: Double, critical: Double) {
        precondition(warning <= critical, "warning threshold must not exceed critical")
        self.warning = warning
        self.critical = critical
    }

    public func health(for value: Double?) -> HealthLevel {
        guard let value, value.isFinite else { return .unknown }
        if value >= critical { return .critical }
        if value >= warning { return .warning }
        return .healthy
    }
}

public struct NetworkThresholds: Sendable, Codable, Equatable {
    public var latencyMs: Threshold
    public var packetLossPercent: Threshold

    public init(
        latencyMs: Threshold = Threshold(warning: 100, critical: 300),
        packetLossPercent: Threshold = Threshold(warning: 2, critical: 10)
    ) {
        self.latencyMs = latencyMs
        self.packetLossPercent = packetLossPercent
    }

    public func health(connectivity: Connectivity?, latencyMs: Double?, packetLossPercent: Double?) -> HealthLevel {
        switch connectivity {
        case nil: return .unknown
        case .offline: return .critical
        case .online:
            let latency = self.latencyMs.health(for: latencyMs)
            let loss = self.packetLossPercent.health(for: packetLossPercent)
            return latency.worst(loss)
        }
    }
}
