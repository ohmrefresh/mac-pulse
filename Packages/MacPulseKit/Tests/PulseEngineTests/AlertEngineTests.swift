import Foundation
import Testing
import PulseCore
@testable import PulseEngine

@Suite struct AlertEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func cpuRule(duration: TimeInterval = 30) -> AlertRule {
        AlertRule(name: "High CPU", metric: .cpuPercent, comparator: .above, threshold: 90,
                  duration: duration, severity: .warning, isEnabled: true)
    }

    /// Feeds one value per second over [from, to) and collects events.
    func run(_ e: inout AlertEngine, _ value: Double, _ from: Int, _ to: Int) -> [AlertEvent] {
        (from..<to).flatMap { e.evaluate(.cpuPercent, value: value, at: at(Double($0))) }
    }

    @Test func firesOnlyAfterDurationHeld() {
        var e = AlertEngine(rules: [cpuRule()])
        #expect(run(&e, 95, 0, 30).isEmpty)                  // t=0…29: pending
        let fired = e.evaluate(.cpuPercent, value: 95, at: at(30))
        #expect(fired.map(\.kind) == [.fired])
        #expect(fired[0].shouldNotify)
        #expect(run(&e, 95, 31, 60).isEmpty)                 // stays firing, no re-notify
    }

    @Test func pendingBreaksWhenConditionClears() {
        var e = AlertEngine(rules: [cpuRule()])
        _ = run(&e, 95, 0, 20)
        _ = e.evaluate(.cpuPercent, value: 50, at: at(20))   // back to inactive
        #expect(run(&e, 95, 21, 50).isEmpty)                 // new pending from 21: fires at 51, not before
        #expect(e.evaluate(.cpuPercent, value: 95, at: at(51)).map(\.kind) == [.fired])
    }

    @Test func resolveNeedsSameDurationFalse() {
        var e = AlertEngine(rules: [cpuRule()])
        _ = run(&e, 95, 0, 31)
        #expect(run(&e, 50, 31, 61).isEmpty)                 // clearing for 29 s
        _ = e.evaluate(.cpuPercent, value: 95, at: at(61))   // blip resets the clearing timer
        #expect(run(&e, 50, 62, 92).isEmpty)
        let resolved = e.evaluate(.cpuPercent, value: 50, at: at(92))
        #expect(resolved.map(\.kind) == [.resolved])
        #expect(!resolved[0].shouldNotify)
        #expect(e.firingRuleIDs.isEmpty)
    }

    @Test func refireWithinCooldownIsLoggedButNotNotified() {
        var e = AlertEngine(rules: [cpuRule(duration: 0)])
        #expect(e.evaluate(.cpuPercent, value: 95, at: at(0)).first?.shouldNotify == true)
        #expect(e.evaluate(.cpuPercent, value: 50, at: at(1)).map(\.kind) == [.resolved])
        let refire = e.evaluate(.cpuPercent, value: 95, at: at(60))
        #expect(refire.map(\.kind) == [.fired])
        #expect(refire[0].shouldNotify == false)            // within 10 min of resolve
        _ = e.evaluate(.cpuPercent, value: 50, at: at(61))
        #expect(e.evaluate(.cpuPercent, value: 95, at: at(61 + 600)).first?.shouldNotify == true)
    }

    @Test func ignoresDisabledRulesAndOtherMetrics() {
        var rule = cpuRule(duration: 0)
        rule.isEnabled = false
        var e = AlertEngine(rules: [rule])
        #expect(e.evaluate(.cpuPercent, value: 99, at: at(0)).isEmpty)
        e.setRules([cpuRule(duration: 0)])
        #expect(e.evaluate(.batteryPercent, value: 99, at: at(0)).isEmpty)
    }

    @Test func editingRuleResetsItsState() {
        let rule = cpuRule(duration: 0)
        var e = AlertEngine(rules: [rule])
        _ = e.evaluate(.cpuPercent, value: 95, at: at(0))
        #expect(e.firingRuleIDs == [rule.id])
        var edited = rule
        edited.threshold = 80
        e.setRules([edited])
        #expect(e.firingRuleIDs.isEmpty)
        e.setRules([edited])                                  // unchanged rule keeps state
        _ = e.evaluate(.cpuPercent, value: 95, at: at(1))
        e.setRules([edited])
        #expect(e.firingRuleIDs == [rule.id])
    }

    @Test func timeoutCountsAsInfiniteLatency() {
        let rule = AlertRule.templates.first { $0.metric == .latencyMs }!
        var enabled = rule
        enabled.isEnabled = true
        enabled.duration = 0
        var e = AlertEngine(rules: [enabled])
        #expect(e.evaluate(.latencyMs, value: .infinity, at: at(0)).map(\.kind) == [.fired])
    }

    @Test func templatesMatchPRD() throws {
        let byName = Dictionary(uniqueKeysWithValues: AlertRule.templates.map { ($0.name, $0) })
        #expect(byName.count == 8)             // PRD §12's six plus Hot CPU and High GPU (Phase 4)
        func check(_ name: String, _ comparator: AlertComparator, _ threshold: Double, _ duration: TimeInterval) throws {
            let r = try #require(byName[name])
            #expect(r.comparator == comparator && r.threshold == threshold && r.duration == duration, "\(name)")
        }
        try check("High CPU", .above, 90, 30)
        try check("Memory Pressure", .atLeast, 3, 15)
        try check("Internet Latency", .above, 300, 20)
        try check("Packet Loss", .above, 10, 0)
        try check("Low Disk", .below, 10, 0)
        try check("Thermal Warning", .atLeast, 2, 0)
        try check("Hot CPU", .above, 95, 60)
        try check("High GPU", .above, 90, 60)
        #expect(AlertRule.templates.allSatisfy { !$0.isEnabled })
    }

    @Test func mergingAddsOnlyMissingTemplatesKeepingEdits() {
        var saved = Array(AlertRule.templates.prefix(6))
        saved[0].threshold = 70
        saved[0].isEnabled = true
        let merged = AlertRule.mergingNewTemplates(into: saved)
        #expect(merged.count == 8)
        #expect(merged[0].threshold == 70 && merged[0].isEnabled)
        #expect(merged.suffix(2).map(\.name) == ["Hot CPU", "High GPU"])
        #expect(AlertRule.mergingNewTemplates(into: merged) == merged)
    }
}
