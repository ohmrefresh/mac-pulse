public enum HealthLevel: Int, Sendable, Codable, CaseIterable {
    case unknown
    case healthy
    case warning
    case critical

    /// Worst of two levels; `unknown` only wins when both are unknown.
    public func worst(_ other: HealthLevel) -> HealthLevel {
        Swift.max(self, other)
    }
}

extension HealthLevel: Comparable {
    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum Connectivity: Sendable, Codable {
    case online
    case offline
}

public enum ThermalState: Int, Sendable, Codable {
    case nominal
    case fair
    case serious
    case critical

    public var health: HealthLevel {
        switch self {
        case .nominal, .fair: .healthy
        case .serious: .warning
        case .critical: .critical
        }
    }
}

public enum MemoryPressure: Sendable, Codable {
    case normal
    case warning
    case critical

    public var health: HealthLevel {
        switch self {
        case .normal: .healthy
        case .warning: .warning
        case .critical: .critical
        }
    }
}
