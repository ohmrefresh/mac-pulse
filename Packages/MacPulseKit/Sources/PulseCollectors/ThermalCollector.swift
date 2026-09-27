import Foundation
import PulseCore

public struct ThermalCollector: Sendable {
    public init() {}

    public func sample() -> ThermalState {
        Self.map(ProcessInfo.processInfo.thermalState)
    }

    static func map(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }
}
