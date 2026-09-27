import Foundation
import Testing
import PulseCore
import PulseEngine
@testable import MacPulse

@MainActor
@Suite struct AppSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "MacPulseTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsMatchPlan() {
        let s = AppSettings(metrics: LiveMetrics(), defaults: freshDefaults())
        #expect(s.menuBarItems == MenuBarItem.defaults)
        #expect(s.menuBarShowsIcons)
        #expect(s.samplingInterval == 1)
        #expect(!s.publicIPEnabled)
        #expect(s.cpuWarningPercent == 80 && s.cpuCriticalPercent == 95)
        #expect(s.alertRules == AlertRule.templates)
        #expect(s.retention == .thirtyDays)
    }

    @Test func valuesPersistAcrossInstances() {
        let d = freshDefaults()
        let a = AppSettings(metrics: LiveMetrics(), defaults: d)
        a.menuBarItems = [.cpu, .temperature]
        a.menuBarShowsIcons = false
        a.samplingInterval = 5
        a.cpuWarningPercent = 70
        a.dnsSlowMs = 350
        a.pingTarget = "9.9.9.9"
        a.retention = .sevenDays
        var rules = a.alertRules
        rules[0].threshold = 75
        a.alertRules = rules

        let b = AppSettings(metrics: LiveMetrics(), defaults: d)
        #expect(b.menuBarItems == [.cpu, .temperature])
        #expect(!b.menuBarShowsIcons)
        #expect(b.samplingInterval == 5 && b.cpuWarningPercent == 70 && b.dnsSlowMs == 350)
        #expect(b.pingTarget == "9.9.9.9" && b.retention == .sevenDays)
        #expect(b.alertRules[0].threshold == 75)
    }

    @Test func savedRulesGainNewTemplates() throws {
        let d = freshDefaults()
        d.set(try JSONEncoder().encode(Array(AlertRule.templates.prefix(6))), forKey: "alertRules")
        let s = AppSettings(metrics: LiveMetrics(), defaults: d)
        #expect(s.alertRules.map(\.name) == AlertRule.templates.map(\.name))
    }

    @Test func deletedTemplateStaysDeletedAcrossLaunches() {
        let d = freshDefaults()
        let a = AppSettings(metrics: LiveMetrics(), defaults: d)
        let packetLoss = a.alertRules.first { $0.name == "Packet Loss" }!
        a.deleteRule(packetLoss.id)
        a.addRule(for: .batteryPercent)
        let b = AppSettings(metrics: LiveMetrics(), defaults: d)
        #expect(!b.alertRules.contains { $0.name == "Packet Loss" })
        #expect(b.alertRules.last?.metric == .batteryPercent && b.alertRules.last?.isEnabled == false)
    }

    @Test func menuBarTogglesKeepCanonicalOrder() {
        let s = AppSettings(metrics: LiveMetrics(), defaults: freshDefaults())
        s.menuBarItems = []
        s.setEnabled(.latency, true)
        s.setEnabled(.cpu, true)
        #expect(s.menuBarItems == [.cpu, .latency])
        s.setEnabled(.cpu, false)
        #expect(s.menuBarItems == [.latency])
    }

    @Test func pingTargetValidation() {
        let s = AppSettings(metrics: LiveMetrics(), defaults: freshDefaults())
        s.pingTarget = "1.1.1.1"
        #expect(s.pingTargetIsValid)
        s.pingTarget = "one.one"
        #expect(!s.pingTargetIsValid)
    }
}

@Suite struct FormatTests {
    @Test func units() {
        #expect(Format.percent(21.6) == "22%")
        #expect(Format.celsius(48.4) == "48°C")
        #expect(Format.health(.critical) == "Critical")
    }
}
