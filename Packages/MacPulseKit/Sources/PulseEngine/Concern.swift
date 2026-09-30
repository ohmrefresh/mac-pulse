import Foundation
import PulseCore

/// The signals a Concern can come from, in reading order: a tie goes to the one read first.
public enum ConcernSignal: CaseIterable, Sendable {
    case cpu, memory, internet, battery, thermal

    /// The Menu Bar item that shows this signal's reading.
    public var menuBarItem: MenuBarItem {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .internet: .latency
        case .battery: .battery
        case .thermal: .thermal
        }
    }

    /// The timeline category whose events record this signal's Health Level changes.
    public var category: TimelineCategory {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .internet: .connectivity
        case .battery: .battery
        case .thermal: .thermal
        }
    }
}

/// The single worst non-Healthy signal right now — the lead on the Popover and the Overview.
public struct Concern: Equatable, Sendable {
    public var signal: ConcernSignal
    public var level: HealthLevel
    /// Signals reading exactly Healthy, in reading order. Unknown ones are never claimed healthy.
    public var healthy: [ConcernSignal]

    /// Nil when nothing is Warning or Critical.
    public static func current(_ levels: [ConcernSignal: HealthLevel]) -> Concern? {
        var worst: (signal: ConcernSignal, level: HealthLevel)?
        for signal in ConcernSignal.allCases {
            guard let level = levels[signal], level >= .warning else { continue }
            if level > (worst?.level ?? .unknown) { worst = (signal, level) }
        }
        guard let worst else { return nil }
        let healthy = ConcernSignal.allCases.filter { levels[$0] == .healthy }
        return Concern(signal: worst.signal, level: worst.level, healthy: healthy)
    }
}

extension LiveMetrics {
    /// Health Level per Concern signal; a signal with no reading yet is absent.
    public var concernLevels: [ConcernSignal: HealthLevel] {
        var levels: [ConcernSignal: HealthLevel] = [:]
        levels[.cpu] = cpuHealth
        levels[.memory] = memory?.pressure?.health
        levels[.internet] = networkHealth?.health
        levels[.battery] = battery?.condition?.health
        levels[.thermal] = thermal?.health
        return levels
    }

    public var concern: Concern? { Concern.current(concernLevels) }

    /// When the Concern's level began, from the live timeline. Nil if that event has aged out of the
    /// live buffer — the state is still true, only its start is unknown.
    public func started(_ concern: Concern) -> Date? {
        recentEvents
            .filter { $0.category == concern.signal.category && $0.severity == concern.level }
            .max { $0.time < $1.time }?
            .time
    }
}
