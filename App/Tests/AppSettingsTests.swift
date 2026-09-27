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

    /// `String(format:)` always writes a "." decimal; these must follow the user's region instead.
    @Test func decimalsFollowTheLocale() {
        #expect(Format.decimal(2.418, places: 2) == 2.418.formatted(.number.precision(.fractionLength(2))))
        #expect(Format.frequency(4.608e9).hasSuffix(" GHz"))
        #expect(Format.watts(0.365) == "\(Format.decimal(365, places: 0)) mW")
        #expect(Format.watts(12.3) == "\(Format.decimal(12.3, places: 2)) W")
        #expect(Format.load(1.5) == Format.decimal(1.5, places: 2))
    }

    /// Values a real machine can produce at the extremes, where a format can go ugly or wrong.
    @Test func extremeValues() {
        #expect(Format.uptime(0) == "0h 0m")
        #expect(Format.uptime(-5) == "0h 0m")              // clock skew must not print a negative
        #expect(Format.uptime(86_400 * 999 + 3_600) == "999d 1h 0m")
        #expect(Format.frequency(0) == "\(Format.decimal(0, places: 2)) GHz")
        #expect(Format.watts(0) == "\(Format.decimal(0, places: 0)) mW")
        #expect(Format.memoryUsage(used: 0, total: 0) == "\(Format.decimal(0, places: 1)) / \(Format.decimal(0, places: 0)) GB")
        #expect(Format.percent(0) == "0%")
        #expect(Format.percent(1_000) == "1000%")          // a runaway reading still renders
    }
}

/// The memory ring and the per-core lines carry meaning by color, so every step has to clear
/// WCAG 1.4.11's 3:1 against the surface it sits on — in both appearances.
@Suite struct ShadeRampTests {
    private let white = (1.0, 1.0, 1.0)
    private let darkSurface = (0.11, 0.11, 0.12)      // macOS dark window background
    private let purple = (0.69, 0.32, 0.87)           // MetricStyle.memory
    private let blue = (0.0, 0.48, 1.0)               // MetricStyle.cpu

    private func ramp(_ base: (Double, Double, Double), count: Int, dark: Bool) -> [(Double, Double, Double)] {
        (0..<count).map { OKLCH.shade(of: base, index: $0, count: count, dark: dark) }
    }

    @Test func memoryRingClearsNonTextContrastInBothAppearances() {
        for step in ramp(purple, count: 5, dark: false) {
            #expect(OKLCH.contrast(step, white) >= 3.0)
        }
        for step in ramp(purple, count: 5, dark: true) {
            #expect(OKLCH.contrast(step, darkSurface) >= 3.0)
        }
    }

    @Test func perCoreLinesClearItToo() {
        // 15 cores plus the total is the widest ramp the app draws.
        for step in ramp(blue, count: 16, dark: false) {
            #expect(OKLCH.contrast(step, white) >= 3.0)
        }
        for step in ramp(blue, count: 16, dark: true) {
            #expect(OKLCH.contrast(step, darkSurface) >= 3.0)
        }
    }

    /// Neighbours cannot reach 3:1 — five steps of one hue that each clear 3:1 against the
    /// background leave no room for it. They stay separated enough to read as distinct steps, and
    /// the band edges (ring insets, stacked-chart hairlines) carry the actual boundary.
    @Test func stepsStayDistinguishableFromTheirNeighbour() {
        for dark in [false, true] {
            let steps = ramp(purple, count: 5, dark: dark)
            for (a, b) in zip(steps, steps.dropFirst()) {
                #expect(OKLCH.contrast(a, b) >= 1.25)
            }
        }
    }

    @Test func rampWalksAwayFromTheBackground() {
        // Light: each step darker than the last. Dark: each step lighter.
        let light = ramp(purple, count: 5, dark: false).map(OKLCH.luminance)
        #expect(zip(light, light.dropFirst()).allSatisfy { $0 > $1 })
        let dark = ramp(purple, count: 5, dark: true).map(OKLCH.luminance)
        #expect(zip(dark, dark.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func conversionRoundTrips() {
        let (l, c, h) = OKLCH.toOKLCH(purple)
        let back = OKLCH.toSRGB(lightness: l, chroma: c, hue: h)
        #expect(abs(back.0 - purple.0) < 0.01)
        #expect(abs(back.1 - purple.1) < 0.01)
        #expect(abs(back.2 - purple.2) < 0.01)
    }
}
