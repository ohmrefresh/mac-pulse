import Foundation
import Testing
import PulseCore
@testable import MacPulse

/// The wording the Timeline and Alerts pages build from engine data.
@Suite struct TimelineAlertsFormattingTests {
    @Test func lastedReadsLikeTheDesign() {
        #expect(Format.lasted(45) == "45 s")
        #expect(Format.lasted(77) == "1 m 17 s")
        #expect(Format.lasted(33 * 60) == "33 m")
        #expect(Format.lasted(3_600 + 5 * 60) == "1 h 5 m")
        #expect(Format.lasted(2 * 3_600) == "2 h")
        #expect(Format.lasted(-3) == "0 s")
    }

    @Test func dayHeadingNamesTodayAndYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let older = calendar.date(byAdding: .day, value: -3, to: now)!
        #expect(Format.dayHeading(now, now: now, calendar: calendar).hasPrefix("Today · "))
        #expect(Format.dayHeading(yesterday, now: now, calendar: calendar).hasPrefix("Yesterday · "))
        #expect(!Format.dayHeading(older, now: now, calendar: calendar).contains("·"))
    }

    @Test func batteryCategoryReadsPower() {
        #expect(TimelineCategory.battery.displayName == "Power")
        #expect(TimelineCategory.battery.rawValue == "battery")
        #expect(Set(TimelineCategory.allCases.map(\.displayName)).count == TimelineCategory.allCases.count)
    }

    @Test func storedRangesHaveSpanNames() {
        #expect(ChartRange.day.spanName == "Last 24 hours")
        #expect(ChartRange.stored.allSatisfy { $0.spanName.hasPrefix("Last ") })
    }

    @Test func everyAlertMetricHasAnArea() {
        let areas = Dictionary(grouping: AlertMetric.allCases, by: \.area)
        #expect(areas[.compute].map(Set.init) == [.cpuPercent, .gpuPercent, .memoryPressure])
        #expect(areas[.thermal].map(Set.init) == [.thermalState, .cpuTemperatureC])
        #expect(areas[.networkAndDisk].map(Set.init) == [.latencyMs, .packetLossPercent, .diskFreeGB])
        #expect(areas[.power] == [.batteryPercent])
    }

    @Test func firesWhenSentence() {
        let cpu = AlertRule(name: "High CPU", metric: .cpuPercent, comparator: .above, threshold: 90,
                            duration: 30, severity: .warning, isEnabled: true)
        #expect(RulePhrase.parts(cpu) == ("CPU", "above 90%", "30 s"))
        #expect(String(RulePhrase.text(cpu).characters) == "CPU above 90% for 30 s")

        let pressure = AlertRule.templates.first { $0.metric == .memoryPressure }!
        #expect(RulePhrase.parts(pressure).condition == "reaches Critical")

        let loss = AlertRule(name: "Packet Loss", metric: .packetLossPercent, comparator: .above, threshold: 10,
                             duration: 0, severity: .critical, isEnabled: false)
        #expect(RulePhrase.parts(loss).duration == nil)
        #expect(String(RulePhrase.text(loss).characters) == "Packet loss above 10% · immediately")

        let slow = AlertRule(name: "Slow", metric: .latencyMs, comparator: .atLeast, threshold: 300,
                             duration: 90, severity: .warning, isEnabled: true)
        #expect(RulePhrase.parts(slow) == ("Internet latency", "at or above 300 ms", "1 m 30 s"))
    }
}
