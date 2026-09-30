import Foundation
import Testing
import PulseCore
import PulseCollectors
@testable import PulseEngine

@Suite struct TimelineEpisodesTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func ev(_ s: Double, _ category: TimelineCategory, _ severity: HealthLevel, _ title: String,
            _ detail: String? = nil) -> TimelineEvent {
        TimelineEvent(time: at(s), category: category, severity: severity, title: title, detail: detail)
    }

    @Test func pairsStartWithRecovery() {
        let start = ev(0, .cpu, .warning, "CPU → Warning", "92%")
        let end = ev(120, .cpu, .healthy, "CPU back to normal", "20%")
        let rows = TimelineEpisodes.group([end, start])  // any order
        #expect(rows.count == 1)
        let r = rows[0]
        #expect(r.isEpisode && !r.isOngoing)
        #expect(r.event == start && r.end == end)
        #expect(r.id == start.id)
        #expect(r.peakSeverity == .warning)
        #expect(r.firstTime == at(0) && r.lastTime == at(120))
        #expect(r.duration == 120)
    }

    @Test func episodeWithoutRecoveryIsOngoing() {
        let rows = TimelineEpisodes.group([ev(0, .connectivity, .critical, "Offline")])
        #expect(rows.count == 1)
        #expect(rows[0].isOngoing)
        #expect(rows[0].end == nil && rows[0].duration == nil)
    }

    @Test func interleavedCategoriesPairIndependently() {
        let rows = TimelineEpisodes.group([
            ev(0, .cpu, .warning, "CPU → Warning"),
            ev(10, .memory, .critical, "Memory pressure → Critical"),
            ev(20, .cpu, .healthy, "CPU back to normal"),
            ev(50, .memory, .healthy, "Memory pressure back to normal"),
        ])
        #expect(rows.count == 2)
        // Newest activity first: memory ended at 50, CPU at 20.
        #expect(rows.map(\.event.category) == [.memory, .cpu])
        #expect(rows[0].duration == 40 && rows[1].duration == 20)
    }

    @Test func escalationFoldsIntoOpenEpisode() {
        let rows = TimelineEpisodes.group([
            ev(0, .network, .warning, "Network → Warning"),
            ev(30, .network, .critical, "Network → Critical"),
            ev(60, .network, .warning, "Network → Warning"),
            ev(90, .network, .healthy, "Network back to normal"),
        ])
        #expect(rows.count == 1)
        #expect(rows[0].event.title == "Network → Warning" && rows[0].event.time == at(0))
        #expect(rows[0].peakSeverity == .critical)
        #expect(rows[0].duration == 90)
    }

    @Test func consecutiveIdenticalEventsCollapse() {
        let rows = TimelineEpisodes.group([
            ev(0, .process, .warning, "Chrome CPU increased"),
            ev(10, .process, .warning, "Chrome CPU increased"),
            ev(20, .process, .warning, "Chrome CPU increased"),
            ev(30, .memory, .warning, "Memory pressure → Warning"),
            ev(40, .process, .warning, "Chrome CPU increased"),
        ])
        #expect(rows.count == 3)
        #expect(rows[0].count == 1 && rows[0].event.time == at(40))
        #expect(rows[1].isOngoing && rows[1].event.category == .memory)
        #expect(rows[2].count == 3)
        #expect(rows[2].event.time == at(20))  // latest occurrence shown
        #expect(rows[2].firstTime == at(0) && rows[2].lastTime == at(20))
        #expect(rows[2].isEpisode == false && rows[2].duration == nil)
    }

    @MainActor @Test func alertsPairByRuleName() {
        func rule(_ name: String) -> AlertRule {
            AlertRule(name: name, metric: .cpuPercent, comparator: .above, threshold: 90, duration: 30,
                      severity: .critical, isEnabled: true)
        }
        func alert(_ r: AlertRule, _ kind: AlertEvent.Kind, _ s: Double) -> TimelineEvent {
            LiveMetrics.timelineEvent(for: AlertEvent(rule: r, kind: kind, value: 95, time: at(s), shouldNotify: true))
        }
        let a = rule("High CPU"), b = rule("CPU pegged")
        let rows = TimelineEpisodes.group([
            alert(a, .fired, 0), alert(b, .fired, 10), alert(b, .resolved, 20), alert(a, .resolved, 60),
        ])
        #expect(rows.count == 2)
        #expect(rows[0].event.title == "High CPU" && rows[0].duration == 60)
        #expect(rows[1].event.title == "CPU pegged" && rows[1].duration == 10)
        #expect(rows[1].end?.title == "CPU pegged resolved")
    }

    /// Real producer output, so renaming a recovery title in `TimelineGenerator` breaks this test.
    @Test func pairsTimelineGeneratorOutput() {
        var g = TimelineGenerator()
        func cpu(_ percent: Double) -> Snapshot {
            var s = Snapshot()
            s.cpu = CPUReading(totalPercent: percent, perCorePercent: [percent])
            return s
        }
        func net(_ c: Connectivity) -> NetworkHealthReading {
            .make(connectivity: c, gateway: nil,
                  internet: c == .online ? ProbeReading(address: "1.1.1.1", latencyMs: 10, lossPercent: 0) : nil,
                  thresholds: NetworkThresholds())
        }
        var events: [TimelineEvent] = []
        events += g.observe(cpu(10), at: at(0))
        events += g.observe(cpu(95), at: at(1))
        events += g.observe(cpu(95), at: at(11))       // CPU → Critical
        events += g.observe(cpu(10), at: at(20))
        events += g.observe(cpu(10), at: at(30))       // CPU back to normal
        events += g.observe(net(.online), interface: "en0", at: at(40))
        events += g.observe(net(.offline), interface: nil, at: at(50))   // Offline
        events += g.observe(net(.online), interface: "en0", at: at(70))  // Back online
        #expect(events.count == 4)
        let rows = TimelineEpisodes.group(events)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.isEpisode && !$0.isOngoing })
        #expect(rows.map(\.event.category) == [.connectivity, .cpu])
        #expect(rows[0].duration == 20 && rows[1].duration == 19)
    }

    @Test func relaunchEndsOpenEpisodesWithUnknownEnd() {
        let rows = TimelineEpisodes.group([
            ev(0, .cpu, .warning, "CPU → Warning"),
            ev(10, .system, .healthy, TimelineEpisodes.monitoringStartedTitle),
            ev(20, .cpu, .warning, "CPU → Warning"),
            ev(50, .cpu, .healthy, "CPU back to normal"),
        ])
        let episodes = rows.filter(\.isEpisode)
        #expect(episodes.count == 2)
        #expect(rows.map(\.event.time) == [at(20), at(10), at(0)])
        let fresh = episodes[0], cut = episodes[1]
        #expect(fresh.event.time == at(20) && fresh.duration == 30 && !fresh.endUnknown && !fresh.isOngoing)
        #expect(cut.event.time == at(0) && cut.endUnknown)
        #expect(!cut.isOngoing && cut.end == nil && cut.duration == nil)
        #expect(rows[1].isEpisode == false && rows[1].event.category == .system)
    }

    /// The event `LiveMetrics.start()` posts, so changing it breaks this test.
    @Test func relaunchBoundaryIsTheEventLiveMetricsPosts() {
        let rows = TimelineEpisodes.group([
            ev(0, .network, .critical, "Network → Critical"),
            LiveMetrics.monitoringStartedEvent(at: at(10)),
        ])
        #expect(rows.first { $0.isEpisode }?.endUnknown == true)
    }

    @Test func healthyEventsWithoutEpisodeStandAlone() {
        let rows = TimelineEpisodes.group([
            ev(0, .battery, .healthy, "Connected to power"),
            ev(10, .cpu, .healthy, "CPU back to normal"),
        ])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.isEpisode && $0.count == 1 })
        #expect(rows[0].event.title == "CPU back to normal")
    }

    @Test func nonRecoveryHealthyEventsDoNotEndAnEpisode() {
        let rows = TimelineEpisodes.group([
            ev(0, .connectivity, .critical, "Offline"),
            ev(10, .connectivity, .healthy, "Network changed", "en0 → en1"),
            ev(20, .connectivity, .healthy, "Back online"),
            ev(30, .process, .warning, "Chrome memory grew"),
            ev(40, .process, .healthy, "Container db started"),
        ])
        #expect(rows.map(\.event.title) == ["Container db started", "Chrome memory grew", "Offline", "Network changed"])
        let offline = rows[2]
        #expect(offline.end?.title == "Back online" && offline.duration == 20)
        #expect(rows[1].isEpisode == false)
    }
}
