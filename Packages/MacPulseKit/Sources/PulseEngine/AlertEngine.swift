import Foundation
import PulseCore

public struct AlertEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case fired, resolved }

    public var rule: AlertRule
    public var kind: Kind
    public var value: Double
    public var time: Date
    /// False inside the cooldown after a resolve: the timeline still logs it, the user is not re-notified.
    public var shouldNotify: Bool
}

/// Rule state machine (plan decision 7): Inactive → Pending → Firing → Resolved.
/// Firing needs the condition held for `duration`; resolving needs it false for the same duration.
/// Pure and clock-free so every transition is testable.
public struct AlertEngine: Sendable {
    public static let cooldown: TimeInterval = 600

    enum Phase: Equatable {
        case inactive
        case pending(since: Date)
        case firing(clearingSince: Date?)
    }

    struct RuleState {
        var phase: Phase = .inactive
        var lastResolved: Date?
    }

    public private(set) var rules: [AlertRule] = []
    private var states: [UUID: RuleState] = [:]

    public init(rules: [AlertRule] = []) {
        setRules(rules)
    }

    /// Keeps state for rules whose condition is unchanged; editing a rule restarts it.
    public mutating func setRules(_ newRules: [AlertRule]) {
        let old = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        states = states.filter { id, _ in newRules.contains { $0.id == id && $0 == old[id] && $0.isEnabled } }
        rules = newRules
    }

    public var firingRuleIDs: Set<UUID> {
        Set(states.compactMap { id, state in
            if case .firing = state.phase { return id }
            return nil
        })
    }

    /// Feeds one observation. Values arrive at each metric's own cadence.
    public mutating func evaluate(_ metric: AlertMetric, value: Double, at now: Date) -> [AlertEvent] {
        var events: [AlertEvent] = []
        for rule in rules where rule.isEnabled && rule.metric == metric {
            var state = states[rule.id] ?? RuleState()
            let breach = rule.comparator.matches(value, rule.threshold)

            switch state.phase {
            case .inactive:
                if breach {
                    if rule.duration <= 0 {
                        events.append(fire(rule, value, now, &state))
                    } else {
                        state.phase = .pending(since: now)
                    }
                }
            case .pending(let since):
                if !breach {
                    state.phase = .inactive
                } else if now.timeIntervalSince(since) >= rule.duration {
                    events.append(fire(rule, value, now, &state))
                }
            case .firing(let clearingSince):
                if breach {
                    state.phase = .firing(clearingSince: nil)
                } else {
                    let start = clearingSince ?? now
                    if now.timeIntervalSince(start) >= rule.duration {
                        state.phase = .inactive
                        state.lastResolved = now
                        events.append(AlertEvent(rule: rule, kind: .resolved, value: value, time: now, shouldNotify: false))
                    } else {
                        state.phase = .firing(clearingSince: start)
                    }
                }
            }
            states[rule.id] = state
        }
        return events
    }

    private func fire(_ rule: AlertRule, _ value: Double, _ now: Date, _ state: inout RuleState) -> AlertEvent {
        state.phase = .firing(clearingSince: nil)
        let inCooldown = state.lastResolved.map { now.timeIntervalSince($0) < Self.cooldown } ?? false
        return AlertEvent(rule: rule, kind: .fired, value: value, time: now, shouldNotify: !inCooldown)
    }
}
