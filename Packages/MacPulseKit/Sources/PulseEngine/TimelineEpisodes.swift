import Foundation
import PulseCore

/// One line of the Timeline: an Episode, or a standalone event repeated `count` times in a row.
public struct TimelineRow: Sendable, Equatable, Identifiable {
    /// Episode: its opening event. Standalone: the latest occurrence.
    public var event: TimelineEvent
    /// The recovery that ended the Episode; nil while it is ongoing, when its end is unknown, and for standalone rows.
    public var end: TimelineEvent?
    /// Still open when monitoring restarted: how it ended wasn't observed. Neither ongoing nor timed.
    public var endUnknown: Bool = false
    public var isEpisode: Bool
    /// Worst severity seen during the Episode; the event's own severity for standalone rows.
    public var peakSeverity: HealthLevel
    /// Episode: start time. Standalone: first occurrence of the run.
    public var firstTime: Date
    /// Latest activity: the end, the last event folded in, or the run's latest occurrence.
    public var lastTime: Date
    /// Occurrences collapsed into a standalone row; 1 for Episodes.
    public var count: Int

    /// The opening event's id for Episodes (stable while it folds and ends), the latest occurrence's otherwise.
    public var id: UUID { event.id }
    public var isOngoing: Bool { isEpisode && end == nil && !endUnknown }
    /// Closed Episodes only; an ongoing one runs until now, which the caller supplies.
    public var duration: TimeInterval? { end.map { $0.time.timeIntervalSince(event.time) } }
}

/// Groups Timeline Events into Episodes (CONTEXT.md) for display. Pure; every event is still recorded.
public enum TimelineEpisodes {
    /// Title fragments the producers use and pairing depends on.
    static let recoveredSuffix = " back to normal"
    static let backOnlineTitle = "Back online"
    static let resolvedSuffix = " resolved"
    /// Posted by `LiveMetrics.start()`; ends every open Episode with an unknown end.
    static let monitoringStartedTitle = "Monitoring started"
    /// Power source changes (category `.battery`, shown as Power).
    public static let connectedToPowerTitle = "Connected to power"
    public static let switchedToBatteryTitle = "Switched to battery power"

    /// Accepts events in any order (sorted here by time) and returns rows newest-first by `lastTime`.
    ///
    /// - A non-Healthy event opens an Episode for its signal: its category, and for alerts also the
    ///   rule name, so different rules never pair. Further non-Healthy events of that signal fold in
    ///   and raise `peakSeverity`.
    /// - Only a recovery closes it ("… back to normal", "Back online", a Healthy thermal change,
    ///   "<rule> resolved"). Other Healthy events ("Network changed", "VPN connected") stand alone.
    /// - "Monitoring started" is a boundary: Episodes still open there get `endUnknown`, and a
    ///   non-Healthy event after it starts a fresh one.
    /// - `.process` never forms Episodes: its warnings have no recovery event.
    /// - Consecutive standalone rows with the same category, title and severity collapse into one.
    public static func group(_ events: [TimelineEvent]) -> [TimelineRow] {
        let ordered = events.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
        var rows: [TimelineRow] = []
        var open: [String: Int] = [:]
        for e in ordered {
            if isRelaunch(e) {
                for i in open.values { rows[i].endUnknown = true }
                open.removeAll()
            }
            let key = signal(of: e)
            if let key, e.severity > .healthy {
                if let i = open[key] {
                    rows[i].peakSeverity = rows[i].peakSeverity.worst(e.severity)
                    rows[i].lastTime = e.time
                } else {
                    open[key] = rows.count
                    rows.append(TimelineRow(event: e, end: nil, isEpisode: true, peakSeverity: e.severity,
                                            firstTime: e.time, lastTime: e.time, count: 1))
                }
            } else if let key, isRecovery(e), let i = open.removeValue(forKey: key) {
                rows[i].end = e
                rows[i].lastTime = e.time
            } else {
                rows.append(TimelineRow(event: e, end: nil, isEpisode: false, peakSeverity: e.severity,
                                        firstTime: e.time, lastTime: e.time, count: 1))
            }
        }
        let newestFirst = rows.enumerated()
            .sorted { ($0.element.lastTime, $0.offset) > ($1.element.lastTime, $1.offset) }
            .map(\.element)
        var collapsed: [TimelineRow] = []
        for row in newestFirst {
            if let last = collapsed.last, !last.isEpisode, !row.isEpisode,
               last.event.category == row.event.category, last.event.title == row.event.title,
               last.event.severity == row.event.severity {
                collapsed[collapsed.count - 1].firstTime = row.firstTime
                collapsed[collapsed.count - 1].count += 1
            } else {
                collapsed.append(row)
            }
        }
        return collapsed
    }

    /// The signal an event belongs to, or nil if it can never be part of an Episode.
    static func signal(of e: TimelineEvent) -> String? {
        switch e.category {
        case .process: return nil
        case .alert:
            let name = e.severity > .healthy || !e.title.hasSuffix(resolvedSuffix)
                ? e.title : String(e.title.dropLast(resolvedSuffix.count))
            return "alert:\(name)"
        default: return e.category.rawValue
        }
    }

    static func isRelaunch(_ e: TimelineEvent) -> Bool {
        e.category == .system && e.title == monitoringStartedTitle
    }

    static func isRecovery(_ e: TimelineEvent) -> Bool {
        guard e.severity == .healthy else { return false }
        switch e.category {
        case .thermal: return true
        case .connectivity: return e.title == backOnlineTitle
        case .alert: return e.title.hasSuffix(resolvedSuffix)
        default: return e.title.hasSuffix(recoveredSuffix)
        }
    }
}
