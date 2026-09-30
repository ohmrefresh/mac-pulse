import Foundation
import Testing
import PulseCore
import PulseEngine
@testable import MacPulse

/// The Timeline row's time column, recovery phrase and status.
@Suite struct TimelineRowPhraseTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.date(bySettingHour: 0, minute: 10, second: 0, of: Date())! }
    private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    private func event(_ time: Date, _ category: TimelineCategory, _ severity: HealthLevel, _ title: String) -> TimelineEvent {
        TimelineEvent(time: time, category: category, severity: severity, title: title)
    }

    @Test func episodeStartedYesterdayCarriesItsDate() {
        let start = today.addingTimeInterval(-20 * 60)   // 23:50 the day before
        let rows = TimelineEpisodes.group([event(start, .memory, .warning, "Memory pressure → Warning"),
                                           event(today, .memory, .healthy, "Memory pressure back to normal")])
        let row = try! #require(rows.first)
        let day = calendar.startOfDay(for: row.lastTime)
        #expect(TimelinePhrase.timeLines(row, day: day)
                == [start.formatted(.dateTime.day().month(.abbreviated)), clock(start)])
        // The same Episode within one day prints the time alone.
        let sameDay = TimelineEpisodes.group([event(today, .memory, .warning, "Memory pressure → Warning"),
                                              event(today.addingTimeInterval(60), .memory, .healthy, "Memory pressure back to normal")])
        #expect(TimelinePhrase.timeLines(sameDay[0], day: calendar.startOfDay(for: today)) == [clock(today)])
    }

    @Test func repeatedRowShowsItsSpan() {
        let first = today.addingTimeInterval(60), last = today.addingTimeInterval(600)
        let rows = TimelineEpisodes.group([event(first, .network, .healthy, "Network changed"),
                                           event(last, .network, .healthy, "Network changed")])
        #expect(rows.count == 1 && rows[0].count == 2)
        #expect(TimelinePhrase.timeLines(rows[0], day: calendar.startOfDay(for: last)) == ["\(clock(first))–", clock(last)])
    }

    @Test func recoveryPhraseFollowsTheEndingEvent() {
        let t = today
        #expect(TimelinePhrase.recovery(event(t, .alert, .healthy, "High CPU resolved")) == "resolved at \(clock(t))")
        #expect(TimelinePhrase.recovery(event(t, .connectivity, .healthy, "Back online")) == "back online at \(clock(t))")
        #expect(TimelinePhrase.recovery(event(t, .memory, .healthy, "Memory pressure back to normal"))
                == "back to normal at \(clock(t))")
        #expect(TimelinePhrase.recovery(event(t, .thermal, .healthy, "Thermal Serious → Nominal")) == "back to normal at \(clock(t))")
    }

    @Test func statusPerRowKind() {
        let t = today
        let closed = TimelineEpisodes.group([event(t, .cpu, .warning, "CPU → Warning"),
                                             event(t.addingTimeInterval(90), .cpu, .healthy, "CPU back to normal")])
        #expect(TimelinePhrase.status(closed[0]) == .lasted(90))
        let ongoing = TimelineEpisodes.group([event(t, .cpu, .warning, "CPU → Warning")])
        #expect(TimelinePhrase.status(ongoing[0]) == .ongoing)
        let unknown = TimelineEpisodes.group([event(t, .cpu, .warning, "CPU → Warning"),
                                              event(t.addingTimeInterval(60), .system, .healthy, "Monitoring started")])
        let row = try! #require(unknown.first { $0.isEpisode })
        #expect(row.endUnknown)
        #expect(TimelinePhrase.status(row) == .endNotRecorded)
        let standalone = TimelineEpisodes.group([event(t, .network, .healthy, "Network changed")])
        #expect(TimelinePhrase.status(standalone[0]) == .none)
    }
}
